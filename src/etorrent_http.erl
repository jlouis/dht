%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc HTTP protocol helpers
%% <p>Etorrent uses the HTTP protocol for tracker communication. What
%% is surprising though is the lack of proper HTTP 1.1 handling at the
%% trackers. They are usually quick hacks to make them work as
%% expected.</p>
%% <p>One of the problems is that content are returned as gzip'ed,
%% even though we did not request it to be such. This module captures
%% the condition and fixes it by ungzipping data as needed.</p>
%% <p>The module is also home to other small HTTP-like helpers</p>
%% @end
-module(etorrent_http).

-include("etorrent_version.hrl").
%% API
-export([request/1, build_encoded_form_rfc1738/1, mk_header/1]).

%% ====================================================================

% @doc Compression (gzip) enabled variant of http:request
% <p>As http:request/1 in the inets application, but also handles gzip. The
% request headers are explicitly handled to deal with badly and poorly
% implemented trackers (most of them)
% </p>
% @end
-type http_response() :: {integer(), term(), iolist()}.
-spec request(string()) -> {error, term()} | {ok, http_response()}.
request(URL) ->
    Ip = etorrent_config:listen_ip(),
    Options = [{pool, default}, {recv_timeout, 15000},
               {connect_options, case Ip of all -> []; _ -> [{ip, Ip}] end}],
    Headers = [{<<"User-Agent">>, binary_to_list(?AGENT_TRACKER_STRING)},
              {<<"Host">>, decode_host(URL)},
              {<<"Accept">>, "*/*"},
              {<<"Accept-Encoding">>, "gzip, identity"}],
    handle_response(hackney:request(get, URL, Headers, <<>>, Options)).

handle_response({ok, Status, RespHeaders, Client}) ->
    case hackney:body(Client) of
        {ok, RespBody, EatenClient} ->
            hackney:close(EatenClient),
            {ok,
             Status,
             RespHeaders,
             handle_response_body(content_encoding(RespHeaders), RespBody)};
        {error, E} ->
            hackney:close(Client),
            {error, E}
    end;
handle_response({error, E}) ->
    {error, E}.

handle_response_body(identity, Body) -> Body;
handle_response_body(gzip, Body) -> binary_to_list(zlib:gunzip(Body)).
    
%% @doc Turn a proplist into a header string
%% @end
mk_header(PropList) ->
    Items = [string:join([Key, header_conv(Value)], "=") ||
		{Key, Value} <- PropList],
    string:join(Items, "&").

%% @doc Convert the list into RFC1738 encoding (URL-encoding).
%% @end
-spec build_encoded_form_rfc1738(string() | binary()) -> string().
build_encoded_form_rfc1738(List) when is_list(List) ->
    Unreserved = rfc_3986_unreserved_characters_set(),
    F = fun (E) ->
                case sets:is_element(E, Unreserved) of
                    true ->
                        E;
                    false ->
                        lists:concat(
                          ["%", io_lib:format("~2.16.0B", [E])])
                end
        end,
    lists:flatten([F(E) || E <- List]);
build_encoded_form_rfc1738(Binary) when is_binary(Binary) ->
    build_encoded_form_rfc1738(binary_to_list(Binary)).

%% ====================================================================

header_conv(N) when is_integer(N) -> integer_to_list(N);
header_conv(Str) when is_list(Str) -> Str.

% Variant that decodes the content headers, handling compression.
content_encoding(Headers) ->
    HeadersDict = hackney_headers:new(Headers),
    case hackney_headers:get_value("content-encoding", HeadersDict) of
        <<"gzip">> -> gzip;
        <<"deflate">> -> deflate;
        _ -> identity
    end.

% Find the correct host name in an URL. It revolves around getting the port
% right.
decode_host(URL) ->
    {_Scheme, _UserInfo, Host, Port, _Path, _Query} =
        etorrent_http_uri:parse(URL),
    case Port of
        80 -> Host;
        N when is_integer(N) ->
            Host ++ ":" ++ integer_to_list(N)
    end.

rfc_3986_unreserved_characters() ->
    % jlouis: I deliberately killed ~ from the list as it seems the Mainline
    %  client doesn't announce this.
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_./".

rfc_3986_unreserved_characters_set() ->
    sets:from_list(rfc_3986_unreserved_characters()).

