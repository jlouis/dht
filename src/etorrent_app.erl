%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Top level application entry point.
%% <p>This module is intended to be used by the application module of
%% OTP and not by a user. Its only interesting clal is
%% profile_output/0 which can be used to do profiling.</p>
%% @end
-module(etorrent_app).
-behaviour(application).

-include("etorrent_version.hrl").

%% API
-export([start/0, start/1, stop/0]).

%% Callbacks
-export([start/2, stop/1, prep_stop/1, profile_output/0]).

-define(RANDOM_MAX_SIZE, 999999999999).
-define(APP, etorrent_core).

start() ->
    start([]).

start(Config) ->
    %% Reverse proplist to follow the same mechanism of duplicate key handling,
    %% as in the proplist module.
    load_config(lists:reverse(Config)),
    % Load app file.
    application:load(?APP),
    {ok, Deps} = application:get_key(?APP, applications),
    true = lists:all(fun ensure_started/1, Deps),
    application:start(?APP).

stop() ->
    application:stop(?APP).

load_config([]) ->
    ok;
load_config([{Key, Val} | Next]) ->
    application:set_env(?APP, Key, Val),
    load_config(Next);
load_config([Key | Next]) ->
    application:set_env(?APP, Key, true),
    load_config(Next).

%% @private
start(_Type, _Args) ->
    consider_profiling(),
    PeerId = generate_peer_id(),
    case etorrent_sup:start_link(PeerId) of
        {ok, Pid} ->
            ok = etorrent_rlimit:init(),
            ok = etorrent_memory_logger:add_handler(),
            ok = etorrent_file_logger:add_handler(),
            ok = etorrent_callback_handler:add_handler(),
            {ok, Pid};
        {error, Err} ->
            {error, Err}
    end.

%% Consider if the profiling should be enabled.
consider_profiling() ->
    case etorrent_config:profiling() of
        true ->
            eprof:start(),
            eprof:start_profiling([self()]);
            false ->
                ignore
    end.

%% @doc Output profile information
%% <p>If profiling was enabled, output profile information in
%% "procs.profile" and "total.profile"</p>
%% @end
profile_output() ->
    eprof:stop_profiling(),
    eprof:log("procs.profile"),
    eprof:analyze(procs),
    eprof:log("total.profile"),
    eprof:analyze(total).

%% @private
prep_stop(_S) ->
    io:format("Shutting down etorrent~n"),
    ok.

%% @private
stop(_State) ->
    ok.

%% @doc Generate a random peer id for use
%% @end
generate_peer_id() ->
    Number = crypto:rand_uniform(0, ?RANDOM_MAX_SIZE),
    Rand = io_lib:fwrite("~B----------", [Number]),
    PeerId = lists:flatten(io_lib:format("-ET~s-~12s", [?VERSION, Rand])),
    list_to_binary(PeerId).


ensure_started(App) ->
    case application:start(App) of
        ok ->
            true;
        {error, {already_started, App}} ->
            true;
        Else ->
            error_logger:error_msg("Couldn't start ~p: ~p", [App, Else]),
            Else
    end.
