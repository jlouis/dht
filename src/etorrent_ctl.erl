%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Control torrents globally
%% <p>This module is used to globally control torrents. You can start
%% a torrent by pointing to a file on disk, and you can stop or a
%% check a torrent.</p>
%% <p>As such, this module is <em>intended</em> to become an API for
%% torrent manipulation in the long run.</p>
%% @end
-module(etorrent_ctl).
-behaviour(gen_server).


-export([start_link/1,

         start/1, start/2, stop/1,
         check/1, pause/1, continue/1,
         local_peer_id/0]).

-export([handle_cast/2, handle_call/3, init/1, terminate/2]).
-export([handle_info/2, code_change/3]).

-define(SERVER, ?MODULE).

-type bcode() :: etorrent_types:bcode().
-type peerid() :: <<_:160>>.

-record(state, {local_peer_id :: binary() }).

%% API

%% =======================================================================

% @doc Start a new etorrent_t_manager process
% @end
-spec start_link(binary()) -> {ok, pid()} | ignore | {error, term()}.
start_link(PeerId) when is_binary(PeerId) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [PeerId], []).

% @doc Ask the manager process to start a new torrent, given in File.
% @end
-spec start(string()) -> ok | {error, term()}.
start(File) ->
    start(File, []).

%% @doc Ask the manager to start a new torrent, given in File
%% Upon completion the given CallBack function is executed in a separate
%% process.
%% @end
-spec start(string(), [Option]) -> {ok, TorrentID} | {error, term()} when
    Option :: {callback, Callback} | paused,
    Callback :: fun (() -> any()),
    TorrentID :: non_neg_integer().
start(File, Options) ->
    gen_server:call(?SERVER, {start, File, Options}, infinity).

% @doc Check a torrents contents
% @end
-spec check(integer()) -> ok.
check(Id) ->
    gen_server:cast(?SERVER, {check, Id}).

% @doc Set the torrent on pause
% @end
-spec pause(integer()) -> ok.
pause(Id) ->
    gen_server:cast(?SERVER, {pause, Id}).

% @doc Set the torrent on play :)
% @end
-spec continue(integer()) -> ok.
continue(Id) ->
    gen_server:cast(?SERVER, {continue, Id}).

% @doc Ask the manager process to stop a torrent, identified by File.
% @end
-spec stop(string()) -> ok.
stop(File) ->
    gen_server:cast(?SERVER, {stop, File}).

%% @doc Get a local peer id (as a binary).
%%
%% Most of the code don't need this function, because the peer id is usually
%% passed as a parameter of the `start_link' function.
%%
%% This function can be used for debugging and inside tests.
-spec local_peer_id() -> peerid().
local_peer_id() ->
    gen_server:call(?SERVER, local_peer_id).

%% =======================================================================

%% @private
init([PeerId]) ->
    %% We trap exits to gracefully stop all torrents on death.
    process_flag(trap_exit, true),
    {ok, #state { local_peer_id = PeerId}}.

%% @private
handle_cast({check, Id}, S) ->
    Child = etorrent_torrent_ctl:lookup_server(Id),
    etorrent_torrent_ctl:check_torrent(Child),
    {noreply, S};

handle_cast({pause, Id}, S) ->
    Child = etorrent_torrent_ctl:lookup_server(Id),
    etorrent_torrent_ctl:pause_torrent(Child),
    {noreply, S};

handle_cast({continue, Id}, S) ->
    Child = etorrent_torrent_ctl:lookup_server(Id),
    etorrent_torrent_ctl:continue_torrent(Child),
    {noreply, S};

handle_cast({stop, F}, S) ->
    stop_torrent(F),
    {noreply, S}.

%% @private
handle_call({start, FileName, Options}, _From, S) ->
    lager:info("Starting torrent from file ~s", [FileName]),
    case load_torrent(FileName) of
        duplicate -> {reply, duplicate, S};
        {ok, Torrent} ->
            TorrentIH = etorrent_metainfo:get_infohash(Torrent),
            TorrentID = etorrent_counters:next(torrent),
            case etorrent_torrent_pool:start_child(
                   {Torrent, FileName, TorrentIH},
                   S#state.local_peer_id,
                   TorrentID,
                   Options) of
                {ok, TorrentPid} ->
                    case proplists:get_value(callback, Options) of
                        undefined -> ok;
                        Callback ->
                            install_callback(TorrentPid, TorrentIH, Callback)
                    end,
                    {reply, {ok, TorrentID}, S};
                {error, {already_started, _Pid}} = Err ->
                    lager:error("Cannot load the torrent ~p twice.", [TorrentIH]),
                    {reply, Err, S};
                {error, Reason} = Err ->
                    lager:error("Unknown error: ~p", [Reason]),
                    {reply, Err, S}
            end;
        {error, Reason} ->
            lager:info("Malformed torrent file ~s, error: ~p", [FileName, Reason]),
            etorrent_event:notify({malformed_torrent_file, FileName}),
            {reply, {error, Reason}, S}
    end;
handle_call(stop_all, _From, S) ->
    stop_all(),
    {reply, ok, S};
handle_call(local_peer_id, _From, S) ->
    {reply, S#state.local_peer_id, S}.

%% @private
handle_info(Info, State) ->
    lager:error("Unknown handle_info event: ~p", [Info]),
    {noreply, State}.

%% @private
terminate(_Event, _S) ->
    stop_all(),
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =======================================================================
stop_torrent(F) ->
    lager:info("Stopping torrent in file ~s", [F]),
    case etorrent_table:get_torrent({filename, F}) of
        not_found -> ok; % Was already removed, it is ok.
        {value, PL} ->
            TorrentIH = proplists:get_value(info_hash, PL),
            etorrent_torrent_pool:terminate_child(TorrentIH),
            ok
    end.

stop_all() ->
    PLS = etorrent_table:all_torrents(),
    [begin
         F = proplists:get_value(filename, PL),
         stop_torrent(F)
     end || PL <- PLS].

-spec load_torrent(string()) -> duplicate
                                | {ok, bcode()}
                                | {error, _Reason}.
load_torrent(F) ->
    case etorrent_table:get_torrent({filename, F}) of
	    not_found -> load_torrent_internal(F);
	    {value, PL} ->
	        case duplicate =:= proplists:get_value(state, PL) of
	            true -> duplicate;
	            false -> load_torrent_internal(F)
	        end
    end.

load_torrent_internal(F) ->
    Workdir = etorrent_config:work_dir(),
    P = filename:join([Workdir, F]),
    etorrent_bcoding:parse_file(P).

install_callback(TorrentPid, InfoHash, Fun) ->
    ok = etorrent_callback_handler:install_callback(TorrentPid, InfoHash, Fun).
