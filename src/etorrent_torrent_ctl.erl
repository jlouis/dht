%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Torrent Control process
%% <p>This process controls a (single) Torrent Download. It is the
%% "first" process started and it checks the torrent for
%% correctness. When it has checked the torrent, it will start up the
%% rest of the needed processes, attach them to the supervisor and
%% then lay dormant for most of the time, until the torrent needs to
%% be stopped again.</p>
%% <p><b>Note:</b> This module is pretty old,
%% and is a prime candidate for some rewriting.</p>
%% @end
-module(etorrent_torrent_ctl).
-behaviour(gen_fsm).
-define(CHECK_WAIT_TIME, 3000).


%% API
-export([start_link/4,
         completed/1,
         pause_torrent/1,
         continue_torrent/1,
         check_torrent/1,
         valid_pieces/1,
         unwanted_pieces/1,
         switch_mode/2,
         update_tracker/1,
         is_partial/1,
         get_mode/1, %% for debugging
         set_peer_id/2]).

%% gproc registry entries
-export([register_server/1,
         lookup_server/1,
         await_server/1]).

%% gen_fsm callbacks
-export([init/1, 
         handle_event/3, 
         initializing/2, 
         waiting/2,
         checking/2,
         started/2, 
         paused/2,
         handle_sync_event/4, 
         handle_info/3, 
         terminate/3,
         code_change/4]).

%% wish API
-export([get_permanent_wishes/1,
         get_unwanted_files/1,
         get_wishes/1,
         set_wishes/2,
         wish_file/2,
         wish_piece/2,
         wish_piece/3,
         subscribe/3]).

%% partial downloading API
-export([unskip_file/2,
         skip_file/2]).


-type peer_id() :: etorrent_types:peer_id().
-type bcode() :: etorrent_types:bcode().
-type torrent_id() :: etorrent_types:torrent_id().
-type file_id() :: etorrent_types:file_id().
-type pieceset() :: etorrent_pieceset:t().
-type pieceindex() :: etorrent_types:piece_index().

%% If wish is [file_id()], for example, [1,2,3], then create
%% a mask which has all parts from files 1, 2, 3.
%% There is some code in `etorrent_io', that tells about how
%% numbering of files works.
-type wish() :: [file_id()] | file_id().
-type wish_list() :: [wish()].


-type file_wish()  :: [integer()] | integer().
-type piece_wish() :: [integer()].

-record(wish, {
    type :: file | piece,
    value :: file_wish() | piece_wish(),
    is_completed = false :: boolean(),
    %% Transient wishes are 
    %% * __small__  
    %% * __hidden__ for fast_resume module
    %% * always on top of the set of wishes.
    is_transient = false :: boolean(),
    subscribed = [] :: [{pid(), reference()}],
    pieceset :: pieceset()
}).

-record(state, {
    id          :: integer() ,
    torrent     :: bcode(),   % Parsed torrent file
    valid       :: pieceset(),
    unwanted    :: pieceset() | undefined,
    unwanted_files :: [file_id()], %% ordset()
    hashes      :: binary(),
    info_hash   :: binary(),  % Infohash of torrent file
    %% Used peer id.
    peer_id     :: binary(),
    %% Default peer id.
    default_peer_id :: binary(),
    parent_pid  :: pid(),
    tracker_pid :: pid(),
    progress    :: pid(),
    wishes = [] :: [#wish{}],
    interval    :: timer:interval(),
    mode = progress :: 'progress' | 'endgame' | atom(),
    %% This field is for passing `paused' flag beetween
    %% the `init' and `initializing' functions.
    %% If the FSM state name is `checking', than this field contains the next
    %% state.
    next_state = stated :: paused | started,
    indexes_to_check :: list(),
    options,
    directory,
    %% Proplist to add into global ETS, when it will be avaiable.
    registration_options = [],
    is_allocated = false :: boolean()
    }).



-spec register_server(torrent_id()) -> true.
register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

-spec lookup_server(torrent_id()) -> pid().
lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

-spec await_server(torrent_id()) -> pid().
await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID)).

server_name(TorrentID) ->
    {etorrent, TorrentID, control}.

%% @doc Start the server process
-spec start_link(integer(), {bcode(), string(), binary()}, binary(), list()) ->
        {ok, pid()} | ignore | {error, term()}.
start_link(Id, {Torrent, TorrentFile, TorrentIH}, PeerId, Options) ->
    Params = [self(), Id, {Torrent, TorrentFile, TorrentIH}, PeerId, Options],
    gen_fsm:start_link(?MODULE, Params, []).

%% @doc Request that the given torrent is checked (eventually again)
%% @end
-spec check_torrent(pid()) -> ok.
check_torrent(Pid) ->
    gen_fsm:send_event(Pid, check_torrent).

%% @doc Tell the controlled the torrent is complete
%% @end
-spec completed(pid()) -> ok.
completed(Pid) ->
    gen_fsm:send_event(Pid, completed).

%% @doc Set the torrent on pause
%% @end
-spec pause_torrent(pid()) -> ok.
pause_torrent(Pid) ->
    gen_fsm:send_event(Pid, pause).

%% @doc Continue leaching or seeding 
%% @end
-spec continue_torrent(pid()) -> ok.
continue_torrent(Pid) ->
    gen_fsm:send_event(Pid, continue).

%% @doc Get the set of valid pieces for this torrent
%% @end
%% TODO: A call from fast_resume after pause/continue can cause a timeout.
-spec valid_pieces(pid()) -> {ok, pieceset()}.
valid_pieces(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, valid_pieces).


-spec unwanted_pieces(pid()) -> {ok, pieceset()}.
unwanted_pieces(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, unwanted_pieces).


switch_mode(Pid, Mode) ->
    gen_fsm:send_all_state_event(Pid, {switch_mode, Mode}).

get_mode(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, get_mode).

%% @doc Connect to the tracker immediately.
%% The call is async.
-spec update_tracker(Pid::pid()) -> ok.
update_tracker(Pid) when is_pid(Pid) ->
    gen_fsm:send_event(Pid, update_tracker).


-spec is_partial(Pid::pid()) -> {ok, boolean()}.
is_partial(Pid) when is_pid(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, is_partial).


%% @doc Pass `undefined' as a `PeerId' to set a default one.
-spec set_peer_id(Pid::pid(), PeerId::peer_id() | undefined) -> ok.
set_peer_id(Pid, PeerId) ->
    gen_fsm:send_all_state_event(Pid, {set_peer_id, PeerId}).


%% =====================\/=== Wish API ===\/===========================

%% @doc Update wishlist.
%%      This function returns __minimized__ version of wishlist.
-spec set_wishes(torrent_id(), wish_list()) -> {ok, wish_list()}.

set_wishes(TorrentID, Wishes) ->
    {ok, FilteredWishes} = set_record_wishes(TorrentID, to_records(Wishes)),
    {ok, to_proplists(FilteredWishes)}.


-spec get_wishes(torrent_id()) -> {ok, wish_list()}.

get_wishes(TorrentID) ->
    {ok, Wishes} = get_record_wishes(TorrentID),
    {ok, to_proplists(Wishes)}.


get_permanent_wishes(TorrentID) ->
    {ok, Wishes} = get_record_wishes(TorrentID),
    {ok, to_proplists([X || X <- Wishes, not X#wish.is_transient])}.


get_unwanted_files(TorrentID) ->
    CtlSrv = lookup_server(TorrentID),
    gen_fsm:sync_send_all_state_event(CtlSrv, get_unwanted_files).


%% @doc Add a file at top of wishlist.
%%      Added file will have highest priority inside this torrent.
-spec wish_file(TorrentId, Wish) -> {ok, wish_list()}
    when
      TorrentId :: torrent_id(),
      Wish :: wish().
    
wish_file(TorrentID, [FileID]) when is_integer(FileID), FileID >= 0 ->
    wish_file(TorrentID, FileID);

wish_file(TorrentID, FileID) ->
    {ok, OldWishes} = get_record_wishes(TorrentID),
    Wish = #wish {
      type = file,
      value = FileID
    },
    NewWishes = [ Wish | OldWishes ],
    {ok, FilteredWishes} = set_record_wishes(TorrentID, NewWishes),
    {ok, to_proplists(FilteredWishes)}.


wish_piece(TorrentID, PieceID) ->
    wish_piece(TorrentID, PieceID, false).


wish_piece(TorrentID, PieceID, IsTemporary) ->
    {ok, OldWishes} = get_record_wishes(TorrentID),
    Wish = #wish {
      type = piece,
      value = PieceID,
      is_transient = IsTemporary
    },
    NewWishes = [ Wish | OldWishes ],
    {ok, FilteredWishes} = set_record_wishes(TorrentID, NewWishes),
    {ok, to_proplists(FilteredWishes)}.


%% @doc If the wish {Type, Value} will be completed,
%%      caller will receive {completed, Ref}.
%%      Use wish_file of wish_piece functions before calling this function.
subscribe(TorrentID, Type, Value) ->
    CtlSrv = lookup_server(TorrentID),
    gen_fsm:sync_send_all_state_event(CtlSrv, {subscribe, Type, Value}).

  
%% @doc Send information to the subscribed processes about wishes.
%% @private
alert_subscribed(Clients) ->
    [Pid ! {completed, Ref} || {Pid, Ref} <- Clients].


%% @doc Do not download selected files.
-spec skip_file(TorrentID, FileID) -> {ok, wish_list()}
    when
      TorrentID :: torrent_id(),
      FileID :: file_id().
    
skip_file(TorrentID, FileID) ->
    CtlSrv = lookup_server(TorrentID),
    gen_fsm:sync_send_all_state_event(CtlSrv, {skip_file, FileID}).


-spec unskip_file(TorrentID, FileID) -> {ok, wish_list()}
    when
      TorrentID :: torrent_id(),
      FileID :: file_id().
    
unskip_file(TorrentID, FileID) ->
    CtlSrv = lookup_server(TorrentID),
    gen_fsm:sync_send_all_state_event(CtlSrv, {unskip_file, FileID}).


%% @private
get_record_wishes(TorrentID) ->
    CtlSrv = lookup_server(TorrentID),
    gen_fsm:sync_send_all_state_event(CtlSrv, get_wishes).


%% @private
set_record_wishes(TorrentID, Wishes) ->
    CtlSrv = lookup_server(TorrentID),
    gen_fsm:sync_send_all_state_event(CtlSrv, {set_wishes, Wishes}).


to_proplists(Records) ->
    [[{type, Type}
     ,{value, Value}
     ,{is_completed, IsCompleted}
     ,{is_transient, IsTransient}
     ] || #wish{ type = Type, 
                value = Value, 
         is_completed = IsCompleted,
         is_transient = IsTransient } <- Records].


to_records(Props) ->
    [#wish{type = proplists:get_value(type, X), 
          value = proplists:get_value(value, X),
   is_transient = proplists:get_value(is_transient, X, false)
   } || X <- Props, is_list(X)].


to_pieceset(TorrentID, #wish{ type = file, value = FileIds }) ->
    etorrent_info:get_mask(TorrentID, FileIds);

to_pieceset(TorrentID, #wish{ type = piece, value = List }) ->
    Pieceset = etorrent_info:get_mask(TorrentID, 0),
    Size = etorrent_pieceset:capacity(Pieceset),
    etorrent_pieceset:from_list(List, Size).


%% @private
validate_wishes(TorrentID, NewWishes, OldWishes, ValidPieces) ->
    val_(TorrentID, NewWishes, OldWishes, ValidPieces, []).
    

%% @doc Fix incomplete wishes.
%% @private
val_(Tid, [NewH|NewT], Old, Valid, Acc) ->
    case search_wish(NewH, Acc) of
    %% Signature is already used
    #wish{} -> 
        val_(Tid, NewT, Old, Valid, Acc);

    false ->
        Rec = case search_wish(NewH, Old) of
                %% New wish
                false ->
                    WishSet = to_pieceset(Tid, NewH),
                    Left = etorrent_pieceset:difference(WishSet, Valid),
                    IsCompleted = etorrent_pieceset:is_empty(Left),
                    NewH#wish {
                      is_completed = IsCompleted,
                      pieceset = WishSet
                    };

                RecI -> 
                    %% If old wish is transient and new is permanent, then set as permanent.
                    RecI#wish{is_transient=(NewH#wish.is_transient 
                                        and RecI#wish.is_transient)}
            end,
        val_(Tid, NewT, Old, Valid, [Rec|Acc])
    end;

val_(_Tid, [], _Old, _Valid, Acc) ->
    %% Transient wishes are always on top of a query.
    lists:keysort(#wish.is_transient, lists:reverse(Acc)).
    

%% @doc Check status of wishes.
%%      This function will be called periditionally.
check_completed(RecList, Valid) ->
    chk_(RecList, Valid, [], []).


chk_([H=#wish{ is_completed = true }|T], Valid, RecAcc, Ready) ->
   chk_(T, Valid, [H|RecAcc], Ready);

chk_([H|T], Valid, RecAcc, Ready) ->
    #wish{ is_completed = false, pieceset = WishSet, is_transient = IsTransient } = H,
 
    Left = etorrent_pieceset:difference(WishSet, Valid),
    IsCompleted = etorrent_pieceset:is_empty(Left),
    Rec = H#wish{ is_completed = IsCompleted },
    case {IsCompleted, IsTransient} of 
        %% Subscribed clients will be alerted. 
        %% Clear subscriptions.
        {true, true} -> 
            chk_(T, Valid, [Rec#wish{ subscribed=[] }|RecAcc], [Rec|Ready]);
        %% Subscribed clients will be alerted. 
        %% Delete element.
        {true, false} -> 
            chk_(T, Valid, RecAcc, [Rec|Ready]);
        {false, _} -> 
            chk_(T, Valid, [Rec|RecAcc], Ready)
    end;

chk_([], _Valid, RecAcc, Ready) ->
    {lists:reverse(RecAcc), lists:reverse(Ready)}.

    
%% @doc Save pid() as subscriber
%%      Client is {pid(), ref()}
%% @private
add_subscribtion(RecList, Type, Value, Client) ->
    sub_(RecList, Type, Value, Client, []).


sub_([#wish{ is_completed = true, type = Type, value = Value }|_]=T, 
        Type, Value, _Client, Acc) ->
    {completed, lists:reverse(Acc, T)};

sub_([H=#wish{ is_completed = false, type = Type, value = Value, 
        subscribed = S }|T], 
        Type, Value, Client, Acc) ->

    NewAcc = [H#wish { subscribed = [Client|S]} | Acc],
    {subscribed, lists:reverse(NewAcc, T)};

sub_([H|T], Type, Value, Client, Acc) ->
    sub_(T, Type, Value, Client, [H|Acc]);

sub_([], _Type, _Value, _Client, Acc) ->
    {completed, lists:reverse(Acc)}.


%% @doc Search the element with the same signature in the array.
%% @private
search_wish(#wish{ type = Type, value = Value },
       [H = #wish{ type = Type, value = Value } | _T]) ->
    H;

search_wish(El, [_H|T]) ->
    search_wish(El, T);

search_wish(_El, []) ->
    false.





%% =====================/\=== Wish API ===/\===========================
    

%% ====================================================================

%% @private
init([Parent, Id, {Torrent, TorrentFile, TorrentIH}, PeerId, Options]) ->
    gen_fsm:send_event_after(0, initialize),
    register_server(Id),
    etorrent_table:new_torrent(TorrentFile, TorrentIH, Parent, Id),
    HashList = etorrent_metainfo:get_pieces(Torrent),
    Hashes   = hashes_to_binary(HashList),
    %% Initial (non in fast resume) state of the torrent:
    InitState = #state{
        id=Id,
        torrent=Torrent,
        info_hash=TorrentIH,
        peer_id=proplists:get_value(peer_id, Options, PeerId),
        default_peer_id=PeerId,
        parent_pid=Parent,
        hashes=Hashes,
        options=Options},
    {ok, initializing, InitState}.

%% @private
initializing(initialize, #state{id=Id} = S) ->
    lager:info("Initialize torrent #~p.", [Id]),

    %% Read the torrent, check its contents for what we are missing
    FastResumePL = etorrent_fast_resume:query_state(Id),
    [lager:debug("Fast resume entry for #~p is empty.", [Id])
     || FastResumePL =:= []],

    S1 = apply_fast_resume(S, FastResumePL),
    S2 = apply_options(S1),
    S3 = registration(S2),
    %% Soft checking
    case FastResumePL of
        [_|_] -> activate_next_state(S3);
        []    -> {next_state, waiting, S3, 0}
    end.

activate_next_state(S=#state{id=Id, parent_pid=Sup, next_state=NextState}) ->
    lager:info("Activate next state ~p.", [NextState]),
    case NextState of
        paused ->
            %% Reset a parent supervisor to a default state.
            %% It is required, if the process was restarted.
            ok = etorrent_torrent_sup:pause(Sup),
            etorrent_table:statechange_torrent(Id, stopped),
            etorrent_event:stopped_torrent(Id),
            {next_state, paused, S};
        started ->
            S1 = start_io(S),
            %% Networking will use the `valid' field.
            S2 = start_networking(S1),
            {next_state, started, S2}
    end.

waiting(timeout, #state{id=Id} = S) ->
    case etorrent_table:acquire_check_token(Id) of
        false ->
            {next_state, waiting, S, ?CHECK_WAIT_TIME};
        true ->
            activate_checking(S)
    end.


activate_checking(S=#state{id=Id, valid=ValidPieces}) ->
    lager:info("Checking the torrent #~p.", [Id]),
    etorrent_table:statechange_torrent(Id, checking),
    Numpieces = etorrent_pieceset:capacity(ValidPieces),
    %% TODO: Indexes can be generated with `lists:seq/3'.
    All = etorrent_pieceset:full(Numpieces),
    Indexes = etorrent_pieceset:to_list(All),
    EmptyPieceSet = etorrent_pieceset:empty(Numpieces),
    S1 = S#state{indexes_to_check=Indexes,
                 valid=EmptyPieceSet},
    S2 = start_io(S1),
    schedule_checking(S2).

schedule_checking(S) ->
    lager:info("Schedule.", []),
    gen_fsm:send_event_after(0, check),
    {next_state, checking, S}.


checking(check, #state{indexes_to_check=[],
                       id=TorrentID} = S) ->
    lager:info("Checking is completed for the torrent #~p.", [TorrentID]),
    ValidPieces = S#state.valid,
    lager:info("Checking summary for #~p: total=~p, valid=~p.",
               [TorrentID,
                etorrent_pieceset:capacity(ValidPieces),
                etorrent_pieceset:size(ValidPieces)]),
    S1 = registration(S),
    %% TODO: update state.
    activate_next_state(S1);
checking(check, #state{indexes_to_check=[I|Is],
                       valid=ValidPieces,
                       id=TorrentID,
                       hashes=Hashes} = S) ->
    lager:info("Checking piece #~p of #~p.", [I, TorrentID]),
    IsValid = is_valid_piece(TorrentID, I, Hashes),
    lager:info("Piece #~p of ~p is ~p.",
               [I, TorrentID,
                case IsValid of true -> valid; false -> invalid end]),
    NewValidPieces = case IsValid of
        true  -> etorrent_pieceset:insert(I, ValidPieces);
        false -> ValidPieces
    end,
    S1 = S#state{indexes_to_check=Is, valid=NewValidPieces},
    schedule_checking(S1).


%% @private
started(check_torrent, S) ->
    activate_checking(S);

started(completed, #state{id=Id, tracker_pid=TrackerPid} = S) ->
    etorrent_event:completed_torrent(Id),
    lager:info("Completed torrent #~p.", [Id]),
    %% Send `event=completed' to the tracker, if it is not a partial torrent.
    [etorrent_tracker_communication:completed(TrackerPid)
     || not is_partial_int(S)],
    {next_state, started, S};

started(pause, #state{id=Id, interval=I} = SO) ->
%   etorrent_event:paused_torrent(Id),
    
    etorrent_table:statechange_torrent(Id, stopped),
    etorrent_event:stopped_torrent(Id),
    ok = etorrent_torrent:statechange(Id, [paused]),
    ok = etorrent_torrent_sup:pause(SO#state.parent_pid),
    {ok, cancel} = timer:cancel(I),

    S = SO#state{ tracker_pid = undefined, 
                     progress = undefined, 
                     interval = undefined },
    {next_state, paused, S};

started(update_tracker, S=#state{id=TorrentID, tracker_pid=TrackerPid}) ->
    lager:debug("Forced tracker update."),
    is_pid(TrackerPid) andalso
    etorrent_tracker_communication:update_tracker(TrackerPid),
    try
        etorrent_dht_tracker:lookup_server(TorrentID)
    of DhtTrackerPid when is_pid(DhtTrackerPid) ->
        etorrent_dht_tracker:update_tracker(DhtTrackerPid)
    catch error:_ ->
        lager:debug("It seems, that DHT is disabled."),
        dht_disabled
    end,
    {next_state, started, S};

started(continue, S) ->
    {next_state, started, S}.



paused(continue, #state{id=Id} = S) ->
    S1 = start_io(S),
    S2 = registration(S1),
    S3 = start_networking(S2),
    ok = etorrent_torrent:statechange(Id, [continue]),
    {next_state, started, S3};
paused(pause, S) ->
    {next_state, paused, S};

paused(update_tracker, S) ->
    %% Ignore the message.
    {next_state, started, S}.



%% @private
handle_event({switch_mode, Mode}, SN, S=#state{mode=Mode}) ->
   {next_state, SN, S};

handle_event({switch_mode, NewMode}, SN, S=#state{mode=OldMode}) ->
    lager:info("Switch mode: ~p => ~p ~n", [OldMode, NewMode]),
    #state{mode=OldMode, parent_pid=Sup, id=TorrentID} = S,

    case NewMode of
    'progress' ->
         ok;

    'endgame' ->
        etorrent_torrent_sup:start_endgame(Sup, TorrentID)
    end,
    ok = etorrent_torrent:statechange(TorrentID, [{set_mode, NewMode}]),
    etorrent_download:switch_mode(TorrentID, OldMode, NewMode),
    {next_state, SN, S#state{mode=NewMode}};

%% Handle `{set_peer_id, PeerId}'.
handle_event({set_peer_id, undefined}, SN, S=#state{default_peer_id=PeerId}) ->
    %% Set default peer id back.
    handle_event({set_peer_id, PeerId}, SN, S);

handle_event({set_peer_id, PeerId}, paused, S=#state{id=TorrentID}) ->
    ok = etorrent_torrent:statechange(TorrentID, [{set_peer_id, PeerId}]),
    {next_state, paused, S#state{peer_id=PeerId}};

handle_event({set_peer_id, PeerId}, started, S=#state{id=TorrentID}) ->
    S1 = restart_networking(S#state{peer_id=PeerId}),
    ok = etorrent_torrent:statechange(TorrentID, [{set_peer_id, PeerId}]),
    {next_state, started, S1}.



%% @private
handle_sync_event(valid_pieces, _, StateName, State) ->
    #state{valid=Valid} = State,
    {reply, {ok, Valid}, StateName, State};

handle_sync_event(unwanted_pieces, _, StateName, State) ->
    #state{unwanted=Unwanted} = State,
    {reply, {ok, Unwanted}, StateName, State};

handle_sync_event(get_unwanted_files, _, StateName, State) ->
    #state{unwanted_files=UnwantedFiles} = State,
    {reply, {ok, UnwantedFiles}, StateName, State};

handle_sync_event(is_partial, _, StateName, State) ->
    {reply, {ok, is_partial_int(State)}, StateName, State};

handle_sync_event(get_mode, _, StateName, State) ->
    {reply, {ok, State#state.mode}, StateName, State};


handle_sync_event({subscribe, Type, Value}, {_Pid, Ref} = Client, SN, SD) ->
    OldWishes = SD#state.wishes,

    case add_subscribtion(OldWishes, Type, Value, Client) of
        {subscribed, NewWishes} ->
            {reply, {subscribed, Ref}, SN, SD#state{wishes=NewWishes}};

        {completed, _NewWishes} ->
            {reply, completed, SN, SD}
    end;

handle_sync_event(get_wishes, _From, SN, SD) ->
    Wishes = SD#state.wishes,
    {reply, {ok, Wishes}, SN, SD};

handle_sync_event({skip_file, FileID}, _From, SN, SD) ->
    #state{
        id=TorrentID,
        unwanted=Unwanted,
        unwanted_files=UnwantedFiles,
        valid=Valid
    } = SD,
    FileIds = add_one_or_many_files(FileID, UnwantedFiles),
    UnwantedFiles2 = etorrent_info:minimize_filelist(TorrentID, FileIds),
    lager:debug("Minimize filelist ~p => ~p.", [FileIds, UnwantedFiles2]),
    %% Files, that were deleted.
%   Merged = ordsets:subtract(UnwantedFiles, UnwantedFiles1),
    FileMask = etorrent_info:get_mask(TorrentID, UnwantedFiles2, false),
    Unwanted2 = etorrent_pieceset:union(Unwanted, FileMask),
    SD1 = SD#state{
        unwanted=Unwanted2,
        unwanted_files=UnwantedFiles2
    },
    etorrent_progress:set_unwanted(TorrentID, Unwanted2),
    update_left_metric(TorrentID, Unwanted, Unwanted2, Valid),
    {reply, ok, SN, SD1};

handle_sync_event({unskip_file, FileID}, _From, SN, SD) ->
    #state{
        id=TorrentID,
        unwanted=Unwanted,
        valid=Valid
    } = SD,
    FileMask = etorrent_info:get_mask(TorrentID, FileID),
    Unwanted2 = etorrent_pieceset:difference(Unwanted, FileMask),
    UnwantedFiles2 = etorrent_info:mask_to_filelist(TorrentID, Unwanted2),
    SD1 = SD#state{
        unwanted=Unwanted2,
        unwanted_files=UnwantedFiles2
    },
    etorrent_progress:set_unwanted(TorrentID, Unwanted2),
    update_left_metric(TorrentID, Unwanted, Unwanted2, Valid),
    {reply, ok, SN, SD1};

handle_sync_event({set_wishes, NewWishes}, _From, SN, 
    SD=#state{id=Id, wishes=OldWishes, valid=ValidPieces}) ->
    Wishes = validate_wishes(Id, NewWishes, OldWishes, ValidPieces),
    
    case SN of
        paused -> skip;
        _ -> 
            Masks = wishes_to_masks(Wishes),
            %% Tell to the progress manager about new list of wanted pieces
            etorrent_progress:set_wishes(Id, Masks)
    end,

    {reply, {ok, Wishes}, SN, SD#state{wishes=Wishes}}.


wishes_to_masks(Wishes) ->
    [X#wish.pieceset || X <- Wishes, not X#wish.is_completed ].


%% Tell the controller we have stored an index for this torrent file
%% @private
handle_info(check_completed, SN, SD=#state{valid = Valid, wishes = Wishes}) ->
    {NewWishes, CompletedWishes} = check_completed(Wishes, Valid),
    [alert_subscribed(Clients) 
        || #wish{subscribed = Clients} 
        <- CompletedWishes],
    {next_state, SN, SD#state{wishes = NewWishes}};

handle_info({piece, {stored, Index}}, started, State) ->
    #state{id=TorrentID, 
        hashes=Hashes, 
        progress=Progress, 
        valid=ValidPieces,
        unwanted=UnwantedPieces} = State,
    Piecehash = fetch_hash(Index, Hashes),
    case etorrent_io:check_piece(TorrentID, Index, Piecehash) of
        {ok, PieceSize} ->
            Peers = etorrent_peer_control:lookup_peers(TorrentID),
            StateChange = 
            case etorrent_pieceset:is_member(Index, UnwantedPieces) of
                true -> []; %% Already subtracted, when the piece was skipped.
                false -> [{subtract_left, PieceSize}]
            end,
            ok = etorrent_torrent:statechange(TorrentID, 
                [{subtract_left_or_skipped, PieceSize}|StateChange]),
            ok = etorrent_piecestate:valid(Index, Peers),
            ok = etorrent_piecestate:valid(Index, Progress),
            NewValidState = etorrent_pieceset:insert(Index, ValidPieces),
            {next_state, started, State#state { valid = NewValidState }};
        wrong_hash ->
            Peers = etorrent_peer_control:lookup_peers(TorrentID),
            ok = etorrent_piecestate:invalid(Index, Progress),
            ok = etorrent_piecestate:unassigned(Index, Peers),
            {next_state, started, State}
    end.


%% @private
terminate(_Reason, _StateName, _S) ->
    ok.

%% @private
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.






%% --------------------------------------------------------------------

apply_options(S=#state{options=Options, peer_id=LocalPeerId}) ->
    %% Rewritten peer id or `undefined'.
    PeerId = proplists:get_value(peer_id, Options),
    %% Rewritten download_dir or `undefined'.
    Dir    = proplists:get_value(directory, Options),
    NextState = case proplists:get_bool(paused, Options) of
                   true  -> paused;
                   false -> started
               end,
    S#state{directory=Dir,
            peer_id=case PeerId of undefined -> LocalPeerId; _ -> PeerId end,
            next_state=NextState}.

%% Read information and calculate a set of metrics.
apply_fast_resume(S=#state{id=Id, torrent=Torrent, hashes=Hashes,
                           peer_id=LocalPeerId, mode=Mode, options=Options,
                           registration_options=RegOpts},
             FastResumePL) ->
    ValidPieces = form_valid_pieceset(Hashes, FastResumePL),
    UnwantedFiles = proplists:get_value(unwanted_files, FastResumePL, []),
    %% Get a list of file ids.
    UnwantedFiles1 = ordsets:from_list(UnwantedFiles),
    %% Convert file ids to pieceset.
    UnwantedPieces = etorrent_info:get_mask(Id, UnwantedFiles),
    assert_valid_unwanted(UnwantedPieces, ValidPieces),

    AU = proplists:get_value(uploaded, FastResumePL, 0),
    AD = proplists:get_value(downloaded, FastResumePL, 0),
    TState = proplists:get_value(state, FastResumePL, unknown),

    %% Rewritten peer id or `undefined'.
    PeerId = proplists:get_value(peer_id, FastResumePL),
    %% Rewritten download_dir or `undefined'.
    Dir    = proplists:get_value(directory, FastResumePL),

    Wishes = proplists:get_value(wishes, FastResumePL, []),
    WishRecordSet = try
        validate_wishes(Id, to_records(Wishes), [], ValidPieces)
        catch error:Reason ->
        lager:error("Wishes from fast_resume module are invalid~n  Reason: ~w",
                    [Reason]),
        []
    end,
    NewRegOpts = [{all_time_uploaded, AU},
                  {all_time_downloaded, AD},
                  {state, TState}],

    S#state{valid=ValidPieces,
            unwanted=UnwantedPieces,
            wishes=WishRecordSet,
            unwanted_files=UnwantedFiles1,
            peer_id=case PeerId of undefined -> LocalPeerId; _ -> PeerId end,
            next_state=case TState of paused -> paused; _ -> started end,
            directory=Dir,
            registration_options=NewRegOpts++RegOpts
           }.


registration(S=#state{}) ->
    #state{id=Id,
           valid=ValidPieces,
           unwanted=UnwantedPieces,
           peer_id=PeerId,
           directory=Dir,
           registration_options=RegOpts,
           torrent=Torrent,
           mode=Mode} = S,
            
    %% Left is a size of an intersection of invalid and wanted pieces in bytes
    Left = calculate_amount_left(Id, ValidPieces, UnwantedPieces, Torrent),
    NumberOfPieces = etorrent_pieceset:capacity(ValidPieces),
    NumberOfValidPieces = etorrent_pieceset:size(ValidPieces),
    NumberOfMissingPieces = NumberOfPieces - NumberOfValidPieces,

    OptFields = [{peer_id, PeerId},
                 {directory, Dir}],
    ReqFields = [{display_name, list_to_binary(etorrent_metainfo:get_name(Torrent))},
                 {uploaded, 0},
                 {downloaded, 0},
                 {left, Left},
                 {total, etorrent_metainfo:get_length(Torrent)},
                 {is_private, etorrent_metainfo:is_private(Torrent)},
                 {pieces, NumberOfValidPieces},
                 {missing, NumberOfMissingPieces},
                 {mode, Mode},
                 {state, unknown}],

    %% Add a torrent entry for this torrent.
    %% @todo Minimize calculation in `etorrent_torrent' module.
    ok = etorrent_torrent:insert(Id, RegOpts ++ OptFields ++ ReqFields),

    S#state{registration_options=[]}.


start_io(S=#state{id=Id, torrent=Torrent, parent_pid=Sup,
                  is_allocated=IsAllocated}) ->
    lager:info("Start IO sub-system for #~p.", [Id]),
    etorrent_torrent_sup:start_io_sup(Sup, Id, Torrent),
    etorrent_torrent_sup:start_pending(Sup, Id),
    etorrent_torrent_sup:start_scarcity(Sup, Id, Torrent),
    case IsAllocated of
        false ->
            etorrent_io:allocate(Id),
            S#state{is_allocated=true};
        true ->
            S
    end.


%% Run this function only when IO-subsystem is active.
start_networking(S=#state{id=Id, torrent=Torrent, valid=ValidPieces, wishes=Wishes,
                          unwanted=UnwantedPieces, parent_pid=Sup}) ->
    lager:info("Start IO networking-system for #~p.", [Id]),
    Masks = wishes_to_masks(Wishes),

    %% Start the progress manager
    {ok, ProgressPid} =
    case etorrent_torrent_sup:start_progress(
          Sup,
          Id,
          Torrent,
          ValidPieces,
          Masks,
          UnwantedPieces) of
        {ok, Pid} ->
            {ok, Pid}; 
        {error, {already_started, Pid}} ->
            %% It is a rare case. For example, etorrent_torrent_sup restarted
            %% all active children.
            lager:debug("Progress manager is already started for ~p.", [Id]),
            {ok, Pid}
    end,

    %% Update the tracking map. This torrent has been started.
    %% Altering this state marks the point where we will accept
    %% Foreign connections on the torrent as well.
    etorrent_table:statechange_torrent(Id, started),
    etorrent_event:started_torrent(Id),

    %% Start the tracker
    {ok, TrackerPid} =
        case etorrent_torrent_sup:start_child_tracker(
              S#state.parent_pid,
              S#state.info_hash,
              S#state.peer_id,
              Id,
              S#state.options) of
            {ok, Pid1} ->
                {ok, Pid1}; 
            {error, {already_started, Pid1}} ->
                {ok, Pid1};
            {error, trackerless} ->
                {ok, undefined}
        end,

    etorrent_torrent_sup:start_peer_sup(S#state.parent_pid, Id),

    {ok, Timer} = timer:send_interval(10000, check_completed),

    S#state{tracker_pid = TrackerPid,
               progress = ProgressPid,
               interval = Timer }.


stop_networking(S=#state{parent_pid=SupPid}) ->
    ok = etorrent_torrent_sup:stop_networking(SupPid),
    S.


restart_networking(S) ->
    start_networking(stop_networking(S)).


%% @todo run this when starting:
%% etorrent_event:seeding_torrent(Id),

%% --------------------------------------------------------------------

calculate_amount_left(TorrentID, Valid, Unwanted, Torrent) ->
    Total          = etorrent_metainfo:get_length(Torrent),
    ValidOrSkipped = etorrent_pieceset:union(Valid, Unwanted),
    Indexes        = etorrent_pieceset:to_list(ValidOrSkipped),
    Sizes = [etorrent_info:piece_size(TorrentID, I) || I <- Indexes],
    Downloaded = lists:sum(Sizes),
    Total - Downloaded.

    
    
%% @doc This simple function transforms the stored state of the torrent 
%%      to the stage of the downloading process. PL is stored in 
%%      the `etorrent_fast_resume' module.
-spec to_stage([{atom(), term()}]) -> atom().
to_stage([]) -> unknown;
to_stage(PL) -> 
    case proplists:get_value(bitfield, PL) of
    undefined ->
        completed;
    _ ->
        incompleted
    end.


-spec is_valid_piece(torrent_id(), pieceindex(), binary()) -> boolean().

is_valid_piece(TorrentID, Index, Hashes) ->
    Hash = fetch_hash(Index, Hashes),
    case etorrent_io:check_piece(TorrentID, Index, Hash) of
        {ok, _}    -> true;
        wrong_hash -> false
    end.


form_valid_pieceset(Hashes, PL) ->
    Numpieces = num_hashes(Hashes),
    Stage = to_stage(PL),
    case Stage of
        unknown -> 
            etorrent_pieceset:empty(Numpieces);
        completed -> 
            etorrent_pieceset:full(Numpieces);
        incompleted ->
            Bin = proplists:get_value(bitfield, PL),
            etorrent_pieceset:from_binary(Bin, Numpieces)
    end.


-spec hashes_to_binary([<<_:160>>]) -> binary().
hashes_to_binary(Hashes) ->
    hashes_to_binary(Hashes, <<>>).


hashes_to_binary([], Acc) ->
    Acc;
hashes_to_binary([H=(<<_:160>>)|T], Acc) ->
    hashes_to_binary(T, <<Acc/binary, H/binary>>).


fetch_hash(Piece, Hashes) ->
    Offset = 20 * Piece,
    case Hashes of
        <<_:Offset/binary, Hash:20/binary, _/binary>> -> Hash;
        _ -> erlang:error(badarg)
    end.


num_hashes(Hashes) ->
    byte_size(Hashes) div 20.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

hashes_to_binary_test_() ->
    Input = [<<1:160>>, <<2:160>>, <<3:160>>],
    Bin = hashes_to_binary(Input),
    [?_assertEqual(<<1:160>>, fetch_hash(0, Bin)),
     ?_assertEqual(<<2:160>>, fetch_hash(1, Bin)),
     ?_assertEqual(<<3:160>>, fetch_hash(2, Bin)),
     ?_assertEqual(3, num_hashes(Bin)),
     ?_assertError(badarg, fetch_hash(-1, Bin)),
     ?_assertError(badarg, fetch_hash(3, Bin))].


-endif.



assert_valid_unwanted(UnwantedPieces, ValidPieces) ->
    UnwantedCount = etorrent_pieceset:capacity(UnwantedPieces),
    ValidCount    = etorrent_pieceset:capacity(ValidPieces),
    [error({assert_valid_unwanted, UnwantedCount, ValidCount})
     || UnwantedCount =/= ValidCount].



%% Here, we calculating, how much the total and left size will change 
%% of wanted parts is changed.
update_left_metric(TorrentID, Unwanted, Unwanted2, Valid) ->
    %% Before
    Invalid       = etorrent_pieceset:difference(Unwanted, Valid),
    InvalidBytes  = etorrent_info:mask_to_size(TorrentID, Invalid),

    %% After
    Invalid2      = etorrent_pieceset:difference(Unwanted2, Valid),
    InvalidBytes2 = etorrent_info:mask_to_size(TorrentID, Invalid2),

    Wanted2       = etorrent_pieceset:inversion(Unwanted2),
    WantedBytes2  = etorrent_info:mask_to_size(TorrentID, Wanted2),

    %% If skip_file   was called, than Invalid >= Invalid2.
    %% If unskip_file was called, than Invalid =< Invalid2.

    %% Maybe positive (skip_file), or negative (unskip_file).
    Sub = InvalidBytes2 - InvalidBytes,
    lager:info("update_left_metric subtracted ~p left bytes.", [Sub]),
    lager:info("Want ~p bytes from ~p torrent.", [WantedBytes2, TorrentID]),

    ok = etorrent_torrent:statechange(TorrentID, [{subtract_left, Sub},
                                                  {set_wanted, WantedBytes2}]).



is_partial_int(State) ->
    #state{unwanted=Unwanted, valid=Valid} = State,
    lager:debug("Unwanted size ~p, valid size ~p.",
                [etorrent_pieceset:size(Unwanted),
                 etorrent_pieceset:size(Valid)]),
    %% It is partial, if there are unwanted, invalid pieces.
    %% If all unwanted pieces are already downloaded (i.e. valid), than
    %% it is not a partial downloading.
    UnwantedInvalid = etorrent_pieceset:difference(Unwanted, Valid),
    not etorrent_pieceset:is_empty(UnwantedInvalid).


add_one_or_many_files(FileID, UnwantedFiles) when is_integer(FileID) ->
    [FileID|UnwantedFiles];
add_one_or_many_files(FileIds, UnwantedFiles) when is_list(FileIds) ->
    FileIds ++ UnwantedFiles.

