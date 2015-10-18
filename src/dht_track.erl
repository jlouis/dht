%%% @doc Track entries in the DHT for an Erlang node
%%
%% Since you have to track entries in the DHT and you have to refresh
%% them at predefined times, we have this module, which makes sure to
%% refresh stored values in the DHT. You can also delete values from
%% the DHT again by calling the `delete/1' method on the stored values
%%
%%% @end
%%% @private
-module(dht_track).
-behaviour(gen_server).
-include("dht_constants.hrl").

%% lifetime API
-export([start_link/0, sync/0]).

%% Operational API
-export([store/2, lookup/1, delete/1]).
-export([info/0]).

%% gen_server API
-export([
         init/1,
         handle_cast/2,
         handle_call/3,
         terminate/2,
         code_change/3,
         handle_info/2
]).

-record(state, { tbl = #{} }).

%% LIFETIME & MANAGEMENT
%% ----------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

sync() ->
    gen_server:call(?MODULE, sync).

%% API
%% ------------------------

store(ID, Location) -> call({store, ID, Location}).

delete(ID) -> call({delete, ID}).

lookup(ID) -> call({lookup, ID}).

info() ->call(info).

call(Msg) ->
    gen_server:call(?MODULE, Msg).


%% CALLBACKS
%% -------------------------

init([]) ->
    {ok, #state { tbl = #{} }}.

handle_call({lookup, ID}, _From, #state { tbl = T } = State) ->
    {reply, maps:get(ID, T, not_found), State};
handle_call({store, ID, Location}, _From, #state { tbl = T } = State) ->
    self() ! {refresh, ID, Location},
    {reply, ok, State#state { tbl = T#{ ID => Location } }};
handle_call({delete, ID}, _From, #state { tbl = T } = State) ->
    {reply, ok, State#state { tbl = maps:remove(ID, T)}};
handle_call(sync, _From, State) ->
    {reply, ok, State};
handle_call(info, _From, #state { tbl = T } = State) ->
    {reply, T, State};
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({refresh, ID, Location}, #state { tbl = T } = State) ->
    case maps:get(ID, T, undefined) of
        undefined ->
            %% Deleted entry, don't do anything
            {noreply, State};
        Location ->
            %% TODO: When refresh fails, we should track what failed here and then report it
            %% back to the process for which we store the entries. But this is for a later extension
            %% of the system.
            ok = refresh(ID, Location),
            dht_time:send_after(?REFRESH_TIME, ?MODULE, {refresh, ID, Location}),
            {noreply, State}
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_How, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% INTERNAL FUNCTIONS
%% ------------------------------

refresh(ID, Location) ->
    #{ store := StoreCandidates } = dht_search:run(find_value, ID),
    Stores = pick(?STORE_COUNT, ID, StoreCandidates),
    store_at_peers(Stores, ID, Location).

store_at_peers(STS, ID, Location) ->
    _ = [dht_net:store({IP, Port}, Token, ID, Location) || {{_ID, IP, Port}, Token} <- STS],
    ok.

pick(K, ID, Candidates) ->
    Ordered = lists:sort(fun({{IDx, _, _}, _}, {{IDy, _, _}, _}) -> dht_metric:d(ID, IDx) < dht_metric:d(ID, IDy) end, Candidates),
    take(K, Ordered).
    
take(0, _Rest) -> [];
take(_K, []) -> [];
take(K, [C | Cs]) -> [C | take(K-1, Cs)].
