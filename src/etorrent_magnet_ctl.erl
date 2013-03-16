-module(etorrent_magnet_ctl).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/5]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(mctl_state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(TorrentIH, LocalPeerID, TorrentID, UrlTiers, Options) ->
    gen_server:start_link(?MODULE, [self(), TorrentIH, LocalPeerID, TorrentID, UrlTiers, Options], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([Parent, TorrentIH, LocalPeerID, TorrentID, UrlTiers, Options]) ->
    etorrent_table:new_torrent("", TorrentIH, Parent, TorrentID),
    ok = etorrent_torrent:insert(
           TorrentID,
           [{peer_id, LocalPeerID}, %% TODO: Add this property, only if local peer id =/= peer id for this torrent
            {display_name, TorrentIH},
            {uploaded, 0},
            {downloaded, 0},
            {all_time_uploaded, 0},
            {all_time_downloaded, 0},
            {left, 0},
            {total, 0},
            {is_private, false},
            {pieces, 0},
            {missing, 0},
            {state, leeching}]),

    {ok, #mctl_state{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

