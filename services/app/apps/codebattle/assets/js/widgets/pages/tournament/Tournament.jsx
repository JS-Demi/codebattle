import React, { useCallback, useEffect, useMemo } from 'react';

import ReactMarkdown from 'react-markdown';
import { useDispatch, useSelector } from 'react-redux';

import TournamentStates from '../../config/tournament';
import { connectToChat } from '../../middlewares/Chat';
import {
  connectToTournament,
  kickFromTournament,
} from '../../middlewares/Tournament';
import * as selectors from '../../selectors';

import CustomTournamentInfoPanel from './CustomTournamentInfoPanel';
import IndividualMatches from './IndividualMatches';
import MatchConfirmationModal from './MatchConfirmationModal';
import Players from './PlayersPanel';
import TeamMatches from './TeamMatches';
import TournamentChat from './TournamentChat';
import TournamentHeader from './TournamentHeader';

function InfoPanel({
  currentUserId, tournament, playersCount,
}) {
  if (
    tournament.state === TournamentStates.waitingParticipants
    && tournament.type !== 'team'
  ) {
    return (
      <div className="d-flex justify-content-center align-items-center h-100">
        <ReactMarkdown source={tournament.description} />
      </div>
    );
  }

  switch (tournament.type) {
    case 'individual':
      return (
        <IndividualMatches
          matches={tournament.matches}
          players={tournament.players}
          playersCount={playersCount}
          currentUserId={currentUserId}
        />
      );
    case 'team':
      return (
        <TeamMatches
          state={tournament.state}
          players={tournament.players}
          teams={tournament.meta.teams}
          matches={tournament.matches}
          currentUserId={currentUserId}
        />
      );
    default:
      return (
        <CustomTournamentInfoPanel
          players={tournament.players}
          matches={tournament.matches}
          tournamentId={tournament.id}
          currentUserId={currentUserId}
          roundsLimit={tournament.meta?.roundsLimit}
          currentRound={tournament.currentRound}
          pageNumber={tournament.playersPageNumber}
          pageSize={tournament.playersPageSize}
        />
      );
  }
}

function Tournament() {
  const dispatch = useDispatch();

  const currentUserId = useSelector(selectors.currentUserIdSelector);
  const isAdmin = useSelector(selectors.currentUserIsAdminSelector);
  const isGuest = useSelector(selectors.currentUserIsGuestSelector);
  const tournament = useSelector(selectors.tournamentSelector);

  const playersCount = useMemo(
    () => Object.keys(tournament.players).length,
    [tournament.players],
  );
  const isOver = useMemo(
    () => [TournamentStates.finished, TournamentStates.cancelled].includes(
      tournament.state,
    ),
    [tournament.state],
  );

  const handleKick = useCallback(event => {
    const { playerId } = event.currentTarget.dataset;
    if (playerId) {
      kickFromTournament(playerId);
    }
  }, []);

  useEffect(() => {
    const clearTournament = connectToTournament()(dispatch);

    return () => {
      clearTournament();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (tournament.isLive) {
      const clearChat = connectToChat(tournament.useChat)(dispatch);

      return () => {
        clearChat();
      };
    }

    return () => { };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (isGuest) {
    return (
      <>
        <h1 className="text-center">{tournament.name}</h1>
        <p className="text-center">
          <span>
            Please
            {' '}
            <a href="/session/new">sign in</a>
            {' '}
            to see the tournament
            details
          </span>
        </p>
      </>
    );
  }

  if (tournament.type === 'stairways') {
    return (
      <>
        <TournamentHeader
          id={tournament.id}
          state={tournament.state}
          breakDurationSeconds={tournament.breakDurationSeconds}
          matchTimeoutSeconds={tournament.matchTimeoutSeconds}
          lastRoundEndedAt={tournament.lastRoundEndedAt}
          lastRoundStartedAt={tournament.lastRoundStartedAt}
          startsAt={tournament.startsAt}
          type={tournament.type}
          accessType={tournament.accessType}
          accessToken={tournament.accessToken}
          isLive={tournament.isLive}
          name={tournament.name}
          players={tournament.players}
          playersCount={playersCount}
          playersLimit={tournament.playersLimit}
          breakState={tournament.breakState}
          creatorId={tournament.creatorId}
          currentUserId={currentUserId}
          level={tournament.level}
          isOver={isOver}
          isOnline={tournament.channel.online}
        />
        Tournament stairways
        {/* Chat  */}
        {/* <StairwayTournamentInfoPanel
          state={tournament.state}
          currentUserId={currentUserId}
          rounds={tournament.rounds}
          players={tournament.players}
        /> */}
        {/* StairwayInfoTable
        tournament state: active, game_over

        views: on approved list, participants list, action
          stairway:
            list round with progress (selected, begin, over, not started),
            round list: buttons
            stairway match panel: (default) players list with info about match progress (won, lost, give_up), task info
            players list (table):
              - player1 (current_user, opponent), state match, action (show)
              - player2, state match, action (show)
        */}
      </>
    );
  }

  return (
    <>
      <MatchConfirmationModal
        players={tournament.players}
        matches={tournament.matches}
        currentUserId={currentUserId}
      />
      <div className="container-fluid mb-2">
        <TournamentHeader
          id={tournament.id}
          state={tournament.state}
          breakDurationSeconds={tournament.breakDurationSeconds}
          matchTimeoutSeconds={tournament.matchTimeoutSeconds}
          lastRoundEndedAt={tournament.lastRoundEndedAt}
          lastRoundStartedAt={tournament.lastRoundStartedAt}
          startsAt={tournament.startsAt}
          type={tournament.type}
          accessType={tournament.accessType}
          accessToken={tournament.accessToken}
          name={tournament.name}
          players={tournament.players}
          playersCount={playersCount}
          playersLimit={tournament.playersLimit}
          breakState={tournament.breakState}
          creatorId={tournament.creatorId}
          currentUserId={currentUserId}
          level={tournament.level}
          isOver={isOver}
          isLive={tournament.isLive}
          isOnline={tournament.channel.online}
        />
      </div>
      <div className="container-fluid mb-2">
        <div className="row flex-lg-row-reverse">
          <div className="col-12 col-lg-9 mb-2 mb-lg-0">
            <div className="bg-white h-100 shadow-sm rounded-lg p-3 overflow-auto">
              <InfoPanel
                tournament={tournament}
                playersCount={playersCount}
                currentUserId={currentUserId}
              />
            </div>
          </div>
          <div className="d-flex flex-column flex-lg-column-reverse col-12 col-lg-3 h-100">
            <Players
              playersCount={tournament.playersCount}
              players={tournament.players}
              canBan={
                isAdmin
                && tournament.state === TournamentStates.waitingParticipants
              }
              handleKick={handleKick}
            />
            {tournament.useChat && (<TournamentChat />)}
          </div>
        </div>
      </div>
    </>
  );
}

export default Tournament;
