defmodule Codebattle.Tournament.Base do
  # credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks

  alias Codebattle.Game
  alias Codebattle.Tournament
  alias Codebattle.WaitingRoom

  @moduledoc """
  Defines interface for tournament type
  """
  @callback build_round_pairs(Tournament.t()) :: {Tournament.t(), list(list(pos_integer()))}
  @callback calculate_round_results(Tournament.t()) :: Tournament.t()
  @callback complete_players(Tournament.t()) :: Tournament.t()
  @callback maybe_create_rematch(Tournament.t(), map()) :: Tournament.t()
  @callback finish_tournament?(Tournament.t()) :: boolean()
  @callback finish_round?(Tournament.t()) :: boolean()
  @callback reset_meta(map()) :: map()
  @callback game_type() :: String.t()

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour Tournament.Base

      alias Codebattle.Bot
      alias Codebattle.Tournament.Score
      alias Codebattle.WaitingRoom

      import Tournament.Helpers
      import Tournament.TaskProvider

      require Logger

      def add_player(tournament, player) do
        Tournament.Players.put_player(tournament, Tournament.Player.new!(player))
        Map.put(tournament, :players_count, players_count(tournament))
      end

      def add_players(tournament, %{users: users}) do
        Enum.reduce(users, tournament, &add_player(&2, &1))
      end

      def join(tournament = %{state: "waiting_participants"}, params = %{users: users}) do
        player_params = Map.drop(params, [:users])
        Enum.reduce(users, tournament, &join(&2, Map.put(player_params, :user, &1)))
      end

      def join(tournament = %{state: "waiting_participants"}, params) do
        player =
          params.user
          |> Map.put(:lang, params.user.lang || tournament.default_language)
          |> Map.put(:team_id, Map.get(params, :team_id))

        if players_count(tournament) < tournament.players_limit do
          add_player(tournament, player)
        else
          tournament
        end
      end

      def join(tournament, _), do: tournament

      def leave(tournament, %{user: user}) do
        leave(tournament, %{user_id: user.id})
      end

      def leave(tournament, %{user_id: user_id}) do
        Tournament.Players.drop_player(tournament, user_id)
        Map.put(tournament, :players_count, players_count(tournament))
      end

      def ban_player(tournament, %{user_id: user_id}) do
        player = Tournament.Players.get_player(tournament, user_id)

        if player do
          Tournament.Players.put_player(tournament, %{
            player
            | score: 0,
              wins_count: 0,
              is_banned: !player.is_banned
          })
        end

        tournament
      end

      def leave(tournament, _user_id), do: tournament

      def open_up(tournament, %{user: user}) do
        if can_moderate?(tournament, user) do
          update_struct(tournament, %{access_type: "public"})
        else
          tournament
        end
      end

      def toggle_show_results(tournament, %{user: user}) do
        if can_moderate?(tournament, user) do
          update_struct(
            tournament,
            %{show_results: !Map.get(tournament, :show_results, true)}
          )
        else
          tournament
        end
      end

      def cancel(tournament, %{user: user}) do
        if can_moderate?(tournament, user) do
          new_tournament = tournament |> update_struct(%{state: "canceled"}) |> db_save!()

          Tournament.GlobalSupervisor.terminate_tournament(tournament.id)

          new_tournament
        else
          tournament
        end
      end

      def restart(tournament, %{user: user}) do
        if can_moderate?(tournament, user) do
          Tournament.Round.disable_all_rounds(tournament.id)

          tournament
          |> update_struct(%{
            players: %{},
            meta: reset_meta(tournament.meta),
            matches: %{},
            break_state: "off",
            players_count: 0,
            current_round_position: 0,
            current_round: nil,
            current_round_id: nil,
            last_round_ended_at: nil,
            last_round_started_at: nil,
            winner_ids: [],
            top_player_ids: [],
            starts_at: DateTime.utc_now(:second) |> DateTime.add(5 * 60, :second),
            state: "waiting_participants"
          })
        else
          tournament
        end
      end

      def restart(tournament, _user), do: tournament

      def start(tournament = %{state: "waiting_participants"}, params = %{user: user}) do
        if can_moderate?(tournament, user) do
          tournament = complete_players(tournament)

          tournament
          |> update_struct(%{
            players_count: players_count(tournament),
            state: "active"
          })
          |> maybe_init_waiting_room(params)
          |> broadcast_tournament_started()
          |> start_round()
        else
          tournament
        end
      end

      def start(tournament, _params), do: tournament

      defp maybe_init_waiting_room(t = %{waiting_room_name: nil}, _params), do: t

      defp maybe_init_waiting_room(tournament, params) do
        WaitingRoom.start_link(Map.put(params, :name, tournament.waiting_room_name))
        Codebattle.PubSub.subscribe("waiting_room:#{tournament.waiting_room_name}")
        tournament
      end

      def start_round_force(tournament, new_round_params \\ %{}) do
        tournament
        |> increment_current_round()
        |> start_round(new_round_params)
      end

      def finish_match(tournament, params) do
        tournament
        |> handle_game_result(params)
        |> maybe_create_rematch(params)
        |> maybe_finish_round()
      end

      def handle_game_result(tournament, params) do
        match = get_match(tournament, params.ref)
        winner_id = pick_game_winner_id(match.player_ids, params.player_results)

        player_results =
          Map.new(params.player_results, fn {player_id, result} ->
            {player_id,
             Map.put(
               result,
               :score,
               get_score(
                 tournament.score_strategy,
                 match.level,
                 result.result_percent,
                 params.duration_sec
               )
             )}
          end)

        Tournament.Matches.put_match(tournament, %{
          match
          | state: params.game_state,
            winner_id: winner_id,
            duration_sec: params.duration_sec,
            player_results: player_results,
            finished_at: TimeHelper.utc_now()
        })

        params.player_results
        |> Map.keys()
        |> Enum.each(fn player_id ->
          player = Tournament.Players.get_player(tournament, player_id)

          if player do
            Tournament.Players.put_player(tournament, %{
              player
              | score: player.score + player_results[player_id].score,
                lang: params.player_results[player_id].lang,
                wins_count:
                  player.wins_count +
                    if(player_results[player_id].result == "won", do: 1, else: 0)
            })
          end
        end)

        tournament
      end

      def remove_pass_code(tournament = %{meta: %{game_passwords: passwords}}, %{
            pass_code: pass_code
          }) do
        if pass_code in passwords do
          update_in(tournament.meta.game_passwords, fn codes ->
            List.delete(codes, pass_code)
          end)
        else
          tournament
        end
      end

      def remove_pass_code(tournament, _params) do
        tournament
      end

      def maybe_finish_round(tournament) do
        if finish_round?(tournament) do
          do_finish_round_and_next_step(tournament)
        else
          tournament
        end
      end

      def finish_round(tournament) do
        WaitingRoom.pause(tournament.waiting_room_name)
        matches_to_finish = get_matches(tournament, "playing")

        Enum.each(
          matches_to_finish,
          fn match ->
            finished_at = TimeHelper.utc_now()
            duration_sec = NaiveDateTime.diff(match.started_at, finished_at)

            player_results = improve_player_results(tournament, match, duration_sec)
            Game.Context.trigger_timeout(match.game_id)

            Tournament.Matches.put_match(tournament, %{
              match
              | state: "timeout",
                player_results: player_results,
                duration_sec: duration_sec,
                finished_at: finished_at
            })

            match = Tournament.Matches.get_match(tournament, match.id)

            Codebattle.PubSub.broadcast("tournament:match:upserted", %{
              tournament: tournament,
              match: match
            })

            player_results
            |> Map.keys()
            |> Enum.each(fn player_id ->
              player = Tournament.Players.get_player(tournament, player_id)

              Tournament.Players.put_player(tournament, %{
                player
                | score: player.score + player_results[player_id].score,
                  lang: player_results[player_id].lang
              })
            end)
          end
        )

        do_finish_round_and_next_step(tournament)
      end

      defp improve_player_results(tournament, match, duration_sec) do
        case Game.Context.fetch_game(match.game_id) do
          {:ok, game = %{is_live: true}} ->
            game
            |> Game.Helpers.get_player_results()
            |> Map.new(fn {player_id, result} ->
              {player_id,
               Map.put(
                 result,
                 :score,
                 get_score(
                   tournament.score_strategy,
                   match.level,
                   result.result_percent,
                   duration_sec
                 )
               )}
            end)

          {:error, _reason} ->
            %{}
        end
      end

      def do_finish_round_and_next_step(tournament) do
        tournament
        |> update_struct(%{
          last_round_ended_at: NaiveDateTime.utc_now(:second),
          show_results: need_show_results?(tournament)
        })
        |> calculate_round_results()
        |> broadcast_round_finished()
        |> maybe_finish_tournament()
        |> start_round_or_break_or_finish()
        |> then(fn tournament ->
          broadcast_tournament_update(tournament)
          tournament
        end)
      end

      def start_rematch(tournament, match_ref) do
        finished_match = get_match(tournament, match_ref)
        new_match_id = matches_count(tournament)
        players = get_players(tournament, finished_match.player_ids)

        case create_rematch_game(tournament, players, new_match_id) do
          nil ->
            # TODO: send message that there is no tasks in task_pack
            nil

          game ->
            build_and_run_match(tournament, players, game, false)
        end

        tournament
      end

      defp pick_game_winner_id(player_ids, player_results) do
        Enum.find(player_ids, &(player_results[&1] && player_results[&1].result == "won"))
      end

      defp start_round_or_break_or_finish(tournament = %{state: "finished"}) do
        tournament
      end

      defp start_round_or_break_or_finish(tournament = %{use_infinite_break: true}) do
        update_struct(tournament, %{break_state: "on"})
      end

      defp start_round_or_break_or_finish(
             tournament = %{
               state: "active",
               break_duration_seconds: break_duration_seconds
             }
           )
           when break_duration_seconds not in [nil, 0] do
        Process.send_after(
          self(),
          {:stop_round_break, tournament.current_round_position},
          :timer.seconds(tournament.break_duration_seconds)
        )

        update_struct(tournament, %{break_state: "on"})
      end

      defp start_round_or_break_or_finish(tournament) do
        start_round_force(tournament)
      end

      defp increment_current_round(tournament) do
        update_struct(tournament, %{
          current_round_position: tournament.current_round_position + 1
        })
      end

      defp start_round(tournament, round_params \\ %{}) do
        tournament
        |> update_struct(%{
          break_state: "off",
          last_round_started_at: NaiveDateTime.utc_now(:second),
          match_timeout_seconds:
            Map.get(round_params, :timeout_seconds, tournament.match_timeout_seconds)
        })
        |> build_and_save_round!()
        |> maybe_preload_tasks()
        |> maybe_set_round_task_ids()
        |> maybe_start_round_timer()
        |> build_round_matches(round_params)
        |> db_save!()
        |> maybe_start_waiting_room()
        |> broadcast_round_created()
      end

      defp maybe_start_waiting_room(tournament = %{waiting_room_name: nil}) do
        tournament
      end

      defp maybe_start_waiting_room(tournament) do
        WaitingRoom.start(tournament.waiting_room_name, tournament.played_pair_ids)
        tournament
      end

      defp maybe_set_round_task_ids(tournament = %{task_provider: "task_pack_per_round"}) do
        update_struct(tournament, %{
          round_task_ids: get_round_task_ids(tournament, tournament.current_round_position)
        })
      end

      defp maybe_set_round_task_ids(tournament = %{current_round_position: 0}) do
        update_struct(tournament, %{round_task_ids: get_round_task_ids(tournament)})
      end

      defp maybe_set_round_task_ids(tournament), do: tournament

      defp build_round_matches(tournament, round_params) do
        tournament
        |> build_round_pairs()
        |> bulk_insert_round_games(round_params)
      end

      defp bulk_insert_round_games({tournament, player_pairs}, round_params) do
        task_id = get_task_id_by_params(round_params)

        player_pairs
        |> Enum.with_index(matches_count(tournament))
        |> Enum.chunk_every(50)
        |> Enum.each(&bulk_create_round_games_and_matches(&1, tournament, task_id))

        tournament
      end

      defp bulk_create_round_games_and_matches(batch, tournament, task_id) do
        reset_task_ids = tournament.task_provider == "task_pack_per_round"

        batch
        |> Enum.map(fn
          # TODO: skip bots game
          # {[p1 = %{is_bot: true}, p2 = %{is_bot: true}], match_id} ->
          #   Tournament.Matches.put_match(tournament, %Tournament.Match{
          #     id: match_id,
          #     state: "canceled",
          #     round_id: tournament.current_round_id,
          #     round_position: tournament.current_round_position,
          #     player_ids: Enum.sort([p1.id, p2.id])
          #   })

          {players = [p1, p2], match_id} ->
            %{
              players: players,
              ref: match_id,
              round_id: tournament.current_round_id,
              state: "playing",
              task: get_task(tournament, task_id),
              timeout_seconds: get_game_timeout(tournament),
              tournament_id: tournament.id,
              type: game_type(),
              use_chat: tournament.use_chat,
              use_timer: tournament.use_timer
            }
        end)
        |> Game.Context.bulk_create_games()
        |> Enum.zip(batch)
        |> Enum.each(fn {game, {players, _match_id}} ->
          build_and_run_match(tournament, players, game, reset_task_ids)
        end)
      end

      defp create_rematch_game(tournament, players, ref) do
        completed_task_ids = Enum.flat_map(players, & &1.task_ids)

        case get_rematch_task(tournament, completed_task_ids) do
          nil ->
            # no more tasks in round tasks, waiting next round
            nil

          task ->
            {:ok, game} =
              Game.Context.create_game(%{
                level: task.level,
                players: players,
                ref: ref,
                round_id: tournament.current_round_id,
                state: "playing",
                task: task,
                timeout_seconds: get_game_timeout(tournament),
                tournament_id: tournament.id,
                type: game_type(),
                use_chat: tournament.use_chat,
                use_timer: tournament.use_timer
              })

            game
        end
      end

      defp build_and_run_match(tournament, players, game, reset_task_ids) do
        match = %Tournament.Match{
          game_id: game.id,
          id: game.ref,
          level: game.level,
          player_ids: players |> Enum.map(& &1.id) |> Enum.sort(),
          round_id: tournament.current_round_id,
          round_position: tournament.current_round_position,
          started_at: TimeHelper.utc_now(),
          state: "playing"
        }

        Tournament.Matches.put_match(tournament, match)

        Enum.each(players, fn player ->
          Tournament.Players.put_player(tournament, %{
            player
            | matches_ids: [match.id | player.matches_ids],
              task_ids:
                if(reset_task_ids, do: [game.task_id], else: [game.task_id | player.task_ids])
          })
        end)

        Codebattle.PubSub.broadcast("tournament:match:upserted", %{
          tournament: tournament,
          match: match
        })
      end

      def update_struct(tournament, params) do
        Map.merge(tournament, params)
      end

      def db_save!(tournament, type \\ nil), do: Tournament.Context.upsert!(tournament, type)

      def build_and_save_round!(tournament) do
        round =
          tournament
          |> Tournament.Round.Context.build()
          |> Tournament.Round.Context.upsert!()

        update_struct(tournament, %{
          current_round_id: round.id
        })
      end

      def create_games_for_waiting_room_pairs(tournament, pairs, matched_with_bot) do
        matched_with_bot
        |> Enum.map(&List.wrap/1)
        |> Enum.concat(pairs)
        |> Enum.chunk_every(50)
        |> Enum.each(&create_games_for_waiting_room_batch(tournament, &1))

        tournament
      end

      def create_games_for_waiting_room_batch(tournament, pairs) do
        pairs
        |> Enum.map(fn
          [id1, id2] = ids ->
            players = get_players(tournament, ids)
            completed_task_ids = Enum.flat_map(players, & &1.task_ids)

            {players, get_rematch_task(tournament, completed_task_ids)}

          [id] ->
            player = get_player(tournament, id)
            opponent_bot = Bot.Context.build() |> Tournament.Player.new!()
            {[player, opponent_bot], get_rematch_task(tournament, player.task_ids)}
        end)
        |> Enum.split_with(fn {player, task_id} -> is_nil(task_id) end)
        |> then(fn {_finished_round_players, players_to_play} ->
          # TODO: We filtered players that solved all round tasks before WR,
          # but if they appear here, we just ignore them.
          players_to_play
          |> Enum.with_index(matches_count(tournament))
          |> Enum.map(fn {{players, task}, match_id} ->
            %{
              players: players,
              ref: match_id,
              round_id: tournament.current_round_id,
              state: "playing",
              task: task,
              timeout_seconds: get_game_timeout(tournament),
              tournament_id: tournament.id,
              type: game_type(),
              use_chat: tournament.use_chat,
              use_timer: tournament.use_timer
            }
          end)
          |> Game.Context.bulk_create_games()
          |> Enum.zip(players_to_play)
          |> Enum.each(fn {game, {players, _task}} ->
            build_and_run_match(tournament, players, game, false)
          end)
        end)

        tournament
      end

      defp maybe_finish_tournament(tournament) do
        if finish_tournament?(tournament) do
          tournament
          |> update_struct(%{state: "finished", finished_at: TimeHelper.utc_now()})
          |> set_stats()
          |> set_winner_ids()
          # |> db_save!()
          |> db_save!(:with_ets)
          |> broadcast_tournament_finished()

          # TODO: implement tournament termination in 15 mins
          # Tournament.GlobalSupervisor.terminate_tournament(tournament.id, 15 mins)
        else
          tournament
        end
      end

      defp set_stats(tournament) do
        update_struct(tournament, %{stats: get_stats(tournament)})
      end

      defp set_winner_ids(tournament) do
        update_struct(tournament, %{winner_ids: get_winner_ids(tournament)})
      end

      defp maybe_start_round_timer(tournament = %{round_timeout_seconds: nil}), do: tournament

      defp maybe_start_round_timer(tournament) do
        Process.send_after(
          self(),
          {:finish_round_force, tournament.current_round_position},
          :timer.seconds(tournament.round_timeout_seconds)
        )

        tournament
      end

      defp broadcast_round_created(tournament) do
        Codebattle.PubSub.broadcast("tournament:round_created", %{tournament: tournament})

        tournament
      end

      defp broadcast_round_finished(tournament) do
        Codebattle.PubSub.broadcast("tournament:round_finished", %{tournament: tournament})
        tournament
      end

      defp broadcast_tournament_started(tournament) do
        Codebattle.PubSub.broadcast("tournament:started", %{tournament: tournament})
        tournament
      end

      defp broadcast_tournament_finished(tournament) do
        Codebattle.PubSub.broadcast("tournament:finished", %{tournament: tournament})
        tournament
      end

      defp get_game_timeout(tournament) do
        if use_waiting_room?(tournament) or tournament.type == "swiss" do
          min(seconds_to_end_round(tournament), tournament.match_timeout_seconds)
        else
          get_round_timeout_seconds(tournament)
        end
      end

      defp seconds_to_end_round(tournament) do
        max(
          get_round_timeout_seconds(tournament) -
            NaiveDateTime.diff(NaiveDateTime.utc_now(), tournament.last_round_started_at),
          0
        )
      end

      defp get_round_timeout_seconds(tournament) do
        tournament.round_timeout_seconds || tournament.match_timeout_seconds
      end

      defp use_waiting_room?(%{waiting_room_name: wrn}) when not is_nil(wrn), do: true
      defp use_waiting_room?(_), do: false

      defp broadcast_tournament_update(tournament) do
        Codebattle.PubSub.broadcast("tournament:updated", %{tournament: tournament})
      end

      defp maybe_preload_tasks(tournament = %{current_round_position: 0}) do
        Tournament.Tasks.put_tasks(tournament, get_all_tasks(tournament))

        tournament
      end

      defp maybe_preload_tasks(tournament), do: tournament

      # defp need_show_results?(tournament = %{type: "arena"}), do: !finish_tournament?(tournament)
      # defp need_show_results?(tournament = %{type: "swiss"}), do: !finish_tournament?(tournament)
      defp need_show_results?(tournament), do: true

      defp get_score("time_and_tests", level, result_percent, duration_sec) do
        Score.TimeAndTests.get_score(level, result_percent, duration_sec)
      end

      defp get_score("win_loss", level, player_result, _duration_sec) do
        Score.WinLoss.get_score(level, player_result)
      end

      defp get_task_id_by_params(%{task_id: task_id}), do: task_id
      defp get_task_id_by_params(_round_params), do: nil
    end
  end
end
