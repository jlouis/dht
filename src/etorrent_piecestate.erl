-module(etorrent_piecestate).
%% This module provides a common interface for processes
%% handling piece state changes.

-export([invalid/2,
         unassigned/2,
         stored/2,
         valid/2]).

-type pieceindex() :: etorrent_types:piece_index().
-type pieces() :: [pieceindex()] | pieceindex().
-type pids() :: [pid()] | pid().


%% @doc
%% @end
-spec invalid(pieces(), pids()) -> ok.
invalid(Pieces, Pids) ->
    notify(Pieces, invalid, Pids).


%% @doc
%% @end
-spec unassigned(pieces(), pids()) -> ok.
unassigned(Pieces, Pids) ->
    notify(Pieces, unassigned, Pids).


%% @doc
%% @end
-spec stored(pieces(), pids()) -> ok.
stored(Pieces, Pids) ->
    notify(Pieces, stored, Pids).


%% @doc
%% @end
-spec valid(pieces(), pids()) -> ok.
valid(Pieces, Pids) ->
    notify(Pieces, valid, Pids).

notify(Pieces, Status, Pid) when is_list(Pieces) ->
    [notify(Piece, Status, Pid) || Piece <- Pieces],
    ok;
notify(Piece, Status, Pids) when is_list(Pids) ->
    [notify(Piece, Status, Pid) || Pid <- Pids],
    ok;
notify(Piece, Status, Pid) ->
    Pid ! {piece, {Status, Piece}},
    ok.

