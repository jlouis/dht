-module(routing_table).
-behaviour(gen_server).

-export([start_link/0, reset/0, insert/2, ranges/0, range/2, delete/2, members/2, is_member/2, invariant/0]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, code_change/3]).

-record(state, {
	table
}).

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

reset() ->
	case whereis(?MODULE) of
	    undefined ->
	        {ok, _} = start_link(),
	        ok;
	    P when is_pid(P) ->
	        gen_server:call(?MODULE, reset)
	end.

insert(Self, Node) ->
	gen_server:call(?MODULE, {insert, Self, Node}).

ranges() ->
	gen_server:call(?MODULE, ranges).

range(ID, Self) ->
	gen_server:call(?MODULE, {range, ID, Self}).

delete(Node, Self) ->
	gen_server:call(?MODULE, {delete, Node, Self}).

members(ID, Self) ->
	gen_server:call(?MODULE, {members, ID, Self}).

is_member(Node, Self) ->
	gen_server:call(?MODULE, {is_member, Node, Self}).

invariant() ->
	gen_server:call(?MODULE, invariant).

%% Callbacks

init([]) ->
	{ok, #state{ table = dht_routing_table:new() }}.

handle_cast(_Msg, State) ->
	{noreply, State}.
	
handle_call(reset, _From, State) ->
	{reply, ok, State#state { table = dht_routing_table:new() }};
handle_call(ranges, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:ranges(RT), State};
handle_call({range, ID, Self}, _From, #state{ table = RT } = State) ->
	{reply, dht_routing_table:range(ID, Self, RT), State};
handle_call({insert, Self, Node}, _From, #state { table = RT } = State) ->
	{reply, ok, State#state { table = dht_routing_table:insert(Self, Node, RT) }};
handle_call({delete, Node, Self}, _From, #state { table = RT } = State) ->
	{reply, ok, State#state { table = dht_routing_table:delete(Node, Self, RT) }};
handle_call({members, ID, Self}, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:members(ID, Self, RT), State};
handle_call({is_member, Node, Self}, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:is_member(Node, Self, RT), State};
handle_call(invariant, _From, #state { table = RT } = State) ->
	{reply, check_invariants(RT), State};
handle_call(_Msg, _From, State) ->
	{reply, {error, unsupported}, State}.

handle_info(_Msg, State) ->
	{noreply, State}.

code_change(_Vsn, State, _Aux) ->
	{ok, State}.
	
terminate(_What, _State) ->
	ok.
	
check_invariants(RT) ->
	check_member_count(RT) andalso check_contiguous(RT).
	
check_member_count([]) -> true;
check_member_count([ {_Min, _Max, Members } | Buckets ]) ->
    case length(Members) =< 8 of
        true ->
        	check_member_count(Buckets);
        false ->
        	{error, member_count}
    end.

check_contiguous([]) -> true;
check_contiguous([{_Min, _Max, _Members}]) -> true;
check_contiguous([{_Low, M1, _Members1}, {M2, High, Members2} | T]) when M1 == M2 ->
  check_contiguous([{M2, High, Members2} | T]);
check_contiguous([_X, _Y | _T]) ->
  {error, not_contiguous}.
