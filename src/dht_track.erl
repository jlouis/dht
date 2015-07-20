%%% @doc Track entries in the DHT for an Erlang node
%%
%% Since you have to track entries in the DHT and you have to refresh
%% them at predefined times, we have this module, which makes sure to
%% refresh stored values in the DHT. You can also delete values from
%% the DHT again by calling the `delete/1' method on the stored values
%%
%% @end
-module(dht_track).
-behaviour(gen_server).
-include("dht_constants.hrl").

%% lifetime API
-export([start_link/0]).

%% Operational API
-export([store/2, delete/1]).

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

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

store(ID, Port) ->
    cast({store, ID, Port}).

delete(ID) ->
    cast({delete, ID}).

cast(Msg) ->
    gen_server:cast(?MODULE, Msg).

init([]) ->
    {ok, #state { tbl = #{} }}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast({store, ID, Loc}, #state { tbl = T }) ->
    self() ! {refresh, ID, Loc},
    {noreply, #state { tbl = T#{ ID => Loc } }};

handle_cast({delete, ID}, #state { tbl = T }) ->
    {noreply, #state { tbl = maps:remove(ID, T)}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({refresh, ID, Port}, #state { tbl = T} = State) ->
    case maps:get(ID, T, undefined) of
        undefined ->
            %% Deleted entry, don't do anything
            {noreply, State};
        {ID, Port} ->
            refresh(ID, Port),
            dht_time:send_after(?REFRESH_TIME, self(), {refresh, ID, Port}),
            {noreply, State}
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_How, _State) ->
    ok.
    
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

refresh(ID, Port) ->
    #{ store := Stores } = dht_search:run(find_value, ID),
    store_at_peers(Stores, ID, Port).

store_at_peers([], _ID, _Loc) -> [];
store_at_peers([{Peer, Token} | Sts], ID, Port) ->
    [dht_net:store(Peer, Token, ID, Port) | store_at_peers(Sts, ID, Port)].
