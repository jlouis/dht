-module(etorrent_tracker).

-behaviour(gen_server).
%% API
-export([start_link/0,
         register_handler/0,
         insert_tracker/1,
         statechange/2,
         all/0,
         lookup/1]).

-export([init/1, handle_call/3, handle_cast/2, code_change/3,
         handle_info/2, terminate/2]).

-record(tracker, { 
        id :: non_neg_integer() | undefined,
        handler_pid :: pid(),
        torrent_id :: non_neg_integer(),
        tracker_url :: string(),
        tier_num :: non_neg_integer(),
        last_announced :: erlang:timestamp() | undefined,
        timeout :: non_neg_integer() | undefined}).

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).
-record(state, { 
        next_id = 1 :: non_neg_integer()
        }).

%% ====================================================================

%% @doc Start the `gen_server' governor.
%% @end
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Called from tracker communication server per torrent.
register_handler() ->
    gen_server:cast(?SERVER, {register_handler, self()}).

-spec insert_tracker([{atom(), term()}]) -> ok.
insert_tracker(PL) ->
    T = props_to_record(PL),
    gen_server:call(?SERVER, {insert_tracker, T}).


%% @doc Return all torrents, sorted by Id
%% @end
-spec all() -> [[{term(), term()}]].
all() ->
    all(#tracker.id).

%% @doc Request a change of state for the tracker
%% <p>The specific What part is documented as the alteration() type
%% in the module.
%% </p>
%% @end
-type alteration() :: term().
-spec statechange(integer(), [alteration()]) -> ok.
statechange(Id, What) ->
    gen_server:cast(?SERVER, {statechange, Id, What}).

%% @doc Return a property list of the tracker identified by Id
%% @end
-spec lookup(integer()) ->
		    not_found | {value, [{term(), term()}]}.
lookup(Id) ->
    case ets:lookup(?TAB, Id) of
	[] -> not_found;
	[M] -> {value, proplistify(M)}
    end.


%% =======================================================================

%% @private
init([]) ->
    _ = ets:new(?TAB, [protected, named_table, {keypos, #tracker.id}]),
    {ok, #state{ }}.

%% @private
%% @todo Avoid downs. Let the called process die.
handle_call({insert_tracker, T=#tracker{id=undefined}}, _, S=#state{next_id=NextId}) ->
    ets:insert_new(?TAB, T#tracker{id=NextId}),
    {reply, {ok, NextId}, S#state{next_id=NextId+1}}.

%% @private
handle_cast({register_handler, Pid}, S) ->
    monitor(process, Pid),
    {noreply, S};
handle_cast({statechange, Id, What}, S) ->
    state_change(Id, What),
    {noreply, S};
handle_cast(_Msg, S) ->
    {noreply, S}.

%% @private
handle_info({'DOWN', _Ref, process, Pid, _}, S) ->
    ets:match_delete(?TAB, #tracker{_='_', handler_pid=Pid}),
    {noreply, S}.

%% @private
code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%% @private
terminate(_Reason, _S) ->
    ok.

%% -----------------------------------------------------------------------

props_to_record(PL) ->
    #tracker { 
        id = proplists:get_value(id, PL),
        handler_pid = proplists:get_value(handler_pid, PL),
        tracker_url = proplists:get_value(tracker_url, PL),
        tier_num = proplists:get_value(tier_num, PL)
        }.


%%--------------------------------------------------------------------
%% Function: all(Pos) -> Rows
%% Description: Return all torrents, sorted by Pos
%%--------------------------------------------------------------------
all(Pos) ->
    Objects = ets:match_object(?TAB, '$1'),
    lists:keysort(Pos, Objects),
    [proplistify(O) || O <- Objects].

proplistify(T) ->
    [{id,               T#tracker.id}
    ,{torrent_id,       T#tracker.torrent_id}].

%% Change the state of the tracker with Id, altering it by the "What" part.
%% Precondition: Torrent exists in the ETS table.
state_change(Id, List) when is_integer(Id) ->
    case ets:lookup(?TAB, Id) of
        [T] ->
            NewT = do_state_change(List, T),
            ets:insert(?TAB, NewT);
        []   ->
            %% This is protection against bad tracker ids.
            lager:error("Not found ~p, skip.", [Id]),
            {error, not_found}
    end.

do_state_change([announced | Rem], T) ->
    do_state_change(Rem, T#tracker{last_announced = os:timestamp()});
do_state_change([], T) ->
    T.
