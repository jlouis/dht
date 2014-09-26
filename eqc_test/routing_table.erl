-module(routing_table).
-behaviour(gen_server).

-export([start_link/0, reset/0]).

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

%% Callbacks

init([]) ->
	{ok, #state{ table = dht_routing_table:new() }}.

handle_cast(_Msg, State) ->
	{noreply, State}.
	
handle_call(reset, _From, State) ->
	{reply, ok, State#state { table = dht_routing_table:new() }};
handle_call(_Msg, _From, State) ->
	{reply, {error, unsupported}, State}.

handle_info(_Msg, State) ->
	{noreply, State}.

code_change(_Vsn, State, _Aux) ->
	{ok, State}.
	
terminate(_What, _State) ->
	ok.
	
