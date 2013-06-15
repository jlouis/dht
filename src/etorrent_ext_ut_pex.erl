-module(etorrent_ext_ut_pex).
-export([decode_msg/1,
         encode_msg/1]).

decode_msg(Msg) when is_binary(Msg) ->
    Dict = etorrent_bcoding:decode(Msg),
    lager:debug("PEX message ~p.", [Dict]),
    {pex, Dict}.


encode_msg({pex, Dict}) ->
    <<>>.

