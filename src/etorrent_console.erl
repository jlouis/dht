%% @doc Console writer.
-module(etorrent_console).
-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, 
        handle_call/3, 
        handle_cast/2, 
        handle_info/2, 
        terminate/2, 
        code_change/3]).


-define(SERVER, ?MODULE).

-type torrent_id() :: integer().


% There are 4 different formats of torrent.
-type etorrent_pl()  :: [{atom(), term()}].

-record(torrent, {
    'id'         :: torrent_id(),
    'wanted'     :: non_neg_integer(),
    'left'       :: integer(),
    'leechers'   :: integer(),
    'seeders'    :: integer(),
    'all_time_downloaded' :: integer(),
    'all_time_uploaded'   :: integer(),
    'downloaded' :: integer(),
    'uploaded'   :: integer(),
    'state'      :: atom(),

    %% Byte per second
    'speed_in'  = 0.0 :: float(),
    'speed_out' = 0.0 :: float()
}).

-record(state, {
    timer :: reference(),
    torrents :: [#torrent{}],
    tick :: integer()
}).


%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    Args = [2000],
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([Timeout]) ->
    timer:send_interval(Timeout, update),
    SD = #state{
        tick = Timeout,
        torrents=[]
    },
    {ok, SD}.

handle_call(_Mess, _From, SD) ->
    {reply, ok, SD}.

handle_cast(_Mess, SD) ->
    {noreply, SD}.


handle_info(update, SD=#state{torrents=OldTorrents, tick=Timeout}) ->
    % proplists from etorrent.
    PLs = query_torrent_list(),
    UnsortedNewTorrents = lists:map(fun to_record/1, PLs),
    NewTorrents = sort_records(UnsortedNewTorrents),
    NewTorrents2 = calc_speed_records(OldTorrents, NewTorrents, Timeout),
    map_records2(fun print_torent_info/2, OldTorrents, NewTorrents2),
    {noreply, SD#state{torrents=NewTorrents2}}.

terminate(_Reason, _SD) ->
    ok.

code_change(_OldVsn, SD, _Extra) ->
    {ok, SD}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------


-spec query_torrent_list() -> [etorrent_pl()].
query_torrent_list() ->
    etorrent_query:torrent_list().


-spec to_record(etorrent_pl()) -> #torrent{}.
to_record(X) ->
    #torrent{
        id       = proplists:get_value('id', X),
        wanted   = proplists:get_value(wanted, X),
        left     = proplists:get_value('left', X),
        leechers = proplists:get_value('leechers', X),
        seeders  = proplists:get_value('seeders', X),
        state    = proplists:get_value('state', X),
        downloaded = proplists:get_value('downloaded', X),
        uploaded   = proplists:get_value('uploaded', X),
        all_time_downloaded = proplists:get_value('all_time_downloaded', X),
        all_time_uploaded   = proplists:get_value('all_time_uploaded', X)
     }.


%% @doc Sort a list by id.
-spec sort_records([#torrent{}]) -> [#torrent{}].
sort_records(List) ->
    lists:keysort(#torrent.id, List).


calc_speed_records(Olds, News, Tick) ->
    FU = fun(#torrent{uploaded=X, speed_out=0.0}, 
             #torrent{uploaded=X, speed_out=0.0}=New) -> New;
            (#torrent{uploaded=X}, 
             #torrent{uploaded=X}=New) -> New#torrent{speed_out=0.0};
            (#torrent{uploaded=O}, 
             #torrent{uploaded=N}=New) -> 
                New#torrent{speed_out=calc_speed(O, N, Tick)}
        end,

    FD = fun(#torrent{downloaded=X, speed_in=0.0}, 
             #torrent{downloaded=X, speed_in=0.0}=New) -> New;
            (#torrent{downloaded=X}, 
             #torrent{downloaded=X}=New) -> New#torrent{speed_in=0.0};
            (#torrent{downloaded=O}, 
             #torrent{downloaded=N}=New) -> 
                New#torrent{speed_in=calc_speed(O, N, Tick)}
        end,

    F = fun(Old, New) -> FU(Old, FD(Old, New)) end,
    map_records(F, Olds, News).


calc_speed(Old, New, Interval) ->
    Bytes = New - Old,
    Seconds = Interval / 1000,
    Bytes / Seconds.



map_records(F, [Old=#torrent{id=Id} | OldT], 
               [New=#torrent{id=Id} | NewT]) ->
    [F(Old, New)|map_records(F, OldT, NewT)];

% Element Old was deleted.
map_records(F, [#torrent{id=OldId} | OldT], 
               [#torrent{id=NewId} | _] = NewT) 
    when NewId>OldId ->
    map_records(F, OldT, NewT);

% Element New was added.
% Add New as is.
map_records(F, OldT, [New | NewT]) -> % Copy new torrent.
    [New|map_records(F, OldT, NewT)];

map_records(_F, _OldLeft, _NewLeft) ->
    [].


map_records2(F, [Old=#torrent{id=Id} | OldT], 
                [New=#torrent{id=Id} | NewT]) ->
    [F(Old, New)|map_records2(F, OldT, NewT)];

% Element Old was deleted.
map_records2(F, [Old=#torrent{id=OldId} | OldT], 
                    [#torrent{id=NewId} | _] = NewT) 
    when NewId>OldId ->
    [F(Old, undefined)|map_records2(F, OldT, NewT)];

% Element New was added.
% Add New as is.
map_records2(F, OldT, [New | NewT]) -> % Copy new torrent.
    [F(undefined, New)|map_records2(F, OldT, NewT)];

map_records2(F, OldT, []) ->
    [F(Old, undefined) || Old <- OldT].


print_torent_info(X, X) -> skip;
print_torent_info(undefined, #torrent{id=Id}) -> 
    log("STARTED torrent #~p.", [Id]);
print_torent_info(#torrent{id=Id}, undefined) -> 
    log("STOPPED torrent #~p.", [Id]);
print_torent_info(_Old, #torrent{state=Status, id=Id, left=Left, wanted=Wanted,
                                 speed_in=SpeedIn, speed_out=SpeedOut})
    when Wanted > 0 -> 
    DownloadedPercent = (Wanted-Left)/Wanted * 100,
    log("~.10s #~p: ~6.2f% ~s in, ~s out", 
        [string:to_upper(atom_to_list(Status)), Id, DownloadedPercent, 
         pretty_speed(SpeedIn), pretty_speed(SpeedOut)]);
print_torent_info(_Old, #torrent{id=Id}) ->
    log("IGNORE torrent #~p.", [Id]).
    
%   'leechers'   :: integer(),
%   'seeders'    :: integer(),
%   'speed_in'  = 0 :: integer(),
%   'speed_out' = 0 :: integer()

log(Pattern, Args) ->
    io:format(user, Pattern ++ "~n", Args),
    ok.

pretty_speed(BPS) when BPS < 1024 ->
    io_lib:format("~7.2f B/s  ", [BPS]);
pretty_speed(BPS) when BPS < 1024*1024 ->
    io_lib:format("~7.2f KiB/s", [BPS / 1024]);
pretty_speed(BPS) ->
    io_lib:format("~7.2f MiB/s", [BPS / (1024*1024)]).



-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


sort_records_test_() ->
    Unsorted = [#torrent{id=1}, #torrent{id=3}, #torrent{id=2}],
    Sorted = sort_records(Unsorted),
    [R1, R2, R3] = Sorted,

    [?_assertEqual(R1#torrent.id, 1)
    ,?_assertEqual(R2#torrent.id, 2)
    ,?_assertEqual(R3#torrent.id, 3)
    ].

-endif.

