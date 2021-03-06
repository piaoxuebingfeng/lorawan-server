%
% Copyright (c) 2016-2017 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
% Gateway interface for the https://github.com/Lora-net/packet_forwarder
% Supports protocol v2.2.0
% See https://github.com/Lora-net/packet_forwarder/blob/master/PROTOCOL.TXT
%
-module(lorawan_gw_forwarder).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("lorawan_server_api/include/lorawan_application.hrl").
-include("lorawan.hrl").

-record(state, {sock, tokens}).

start_link(PktFwdOpts) ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [PktFwdOpts], []).

init([PktFwdOpts]) ->
    % We set the port to 0 because it is given in the Opts directly.
    % The port in the options takes precedence over the one in the first argument.
    case gen_udp:open(0, [binary | PktFwdOpts]) of
        {ok, Socket} ->
            {ok, #state{sock=Socket, tokens=maps:new()}};
        {error, Reason} ->
            lager:error("Failed to start the packet_forwarder interface: ~w", Reason),
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {stop, {error, unknownmsg}, State}.

handle_cast({send, {Host, Port, Version}, DevAddr, TxQ, RFCh, PHYPayload},
        #state{sock=Socket, tokens=Tokens}=State) ->
    Pk = [{txpk, build_txpk(TxQ, RFCh, PHYPayload)}],
    % lager:debug("<--- ~w", [Pk]),
    Token = crypto:strong_rand_bytes(2),
    {ok, Timer} = timer:send_after(30000, {no_ack, Token}),
    % PULL RESP
    gen_udp:send(Socket, Host, Port, <<Version, Token/binary, 3, (jsx:encode(Pk))/binary>>),
    {noreply, State#state{tokens=maps:put(Token, {Timer, DevAddr}, Tokens)}}.

% PUSH DATA
handle_info({udp, Socket, Host, Port, <<Version, Token:16, 0, MAC:8/binary, Data/binary>>}, #state{sock=Socket}=State) ->
    case jsx:is_json(Data) of
        true ->
            Data2 = jsx:decode(Data, [return_maps, {labels, atom}]),
            % lager:debug("---> ~w", [Data2]),
            lists:foreach(
                fun ({rxpk, Pk}) -> rxpk(MAC, Pk);
                    ({stat, Pk}) -> status(MAC, Pk)
                end,
                maps:to_list(Data2)),
            % PUSH ACK
            gen_udp:send(Socket, Host, Port, <<Version, Token:16, 1>>);
        false ->
            lager:error("Ignored PUSH_DATA: JSON syntax error")
    end,
    {noreply, State};

% PULL DATA
handle_info({udp, Socket, Host, Port, <<Version, Token:16, 2, MAC:8/binary>>}, #state{sock=Socket}=State) ->
    lorawan_gw_router:register(MAC, {global, ?MODULE}, {Host, Port, Version}),
    lorawan_gw_router:status(MAC, undefined),
    % PULL ACK
    gen_udp:send(Socket, Host, Port, <<Version, Token:16, 4>>),
    {noreply, State};

% TX ACK
handle_info({udp, Socket, _Host, _Port, <<_Version, _Token:16, 5, _MAC:8/binary>>}, #state{sock=Socket}=State) ->
    % no error occured
    {noreply, State};

% TX ACK
handle_info({udp, Socket, _Host, _Port, <<_Version, Token:16, 5, MAC:8/binary, Data/binary>>},
        #state{sock=Socket, tokens=Tokens}=State) ->
    {Opaque, Tokens2} =
        case maps:take(Token, Tokens) of
            {{Timer, Opq}, Tkns} ->
                timer:cancel(Timer),
                {Opq, Tkns};
            error ->
                {undefined, Tokens}
        end,
    case jsx:is_json(Data) of
        true ->
            Data2 = jsx:decode(Data, [return_maps, {labels, atom}]),
            Ack = maps:get(txpk_ack, Data2),
            case maps:get(error, Ack, undefined) of
                undefined -> ok;
                <<"NONE">> -> ok;
                Error ->
                    lorawan_gw_router:downlink_error(MAC, Opaque, Error)
            end;
        false ->
            lager:error("Ignored PUSH_DATA: JSON syntax error")
    end,
    {noreply, State#state{tokens=Tokens2}};

% something strange
handle_info({udp, _Socket, _Host, _Port, _Msg}, State) ->
    {noreply, State};

handle_info({no_ack, Token}, #state{tokens=Tokens}=State) ->
    case maps:take(Token, Tokens) of
        {_, Tokens2} ->
            {noreply, State#state{tokens=Tokens2}};
        error ->
            {noreply, State}
    end.

terminate(Reason, _State) ->
    % record graceful shutdown in the log
    lager:info("packet_forwarder interface terminated: ~w", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


status(MAC, Pk) ->
    lorawan_gw_router:status(MAC, ?to_record(stat, Pk)).


rxpk(MAC, PkList) ->
    Stamp = erlang:monotonic_time(milli_seconds),
    lorawan_gw_router:uplinks(
        lists:map(
            fun(Pk) ->
                {RxQ, Data} = parse_rxpk(Pk),
                {MAC, RxQ#rxq{srvtmst=Stamp}, Data}
            end, PkList)).

parse_rxpk(Pk) ->
    Data = base64:decode(maps:get(data, Pk)),
    case maps:get(modu, Pk) of
        <<"LORA">> ->
            RxQ = list_to_tuple([rxq|[get_rxpk_field(X, Pk) || X <- record_info(fields, rxq)]]),
            {RxQ, Data}
    end.

get_rxpk_field(time, List) ->
    case maps:get(time, List, undefined) of
        undefined -> undefined;
        Value -> iso8601:parse_exact(Value)
    end;
get_rxpk_field(Field, List) ->
    maps:get(Field, List, undefined).


build_txpk(TxQ, RFch, Data) ->
    lists:foldl(
        fun ({_, undefined}, Acc) ->
                Acc;
            ({tmst, Time}, Acc) ->
                [{imme, false}, {tmst, Time} | Acc];
            ({time, immediately}, Acc) ->
                [{imme, true} | Acc];
            ({time, Time}, Acc) ->
                [{imme, false}, {time, iso8601:format(Time)} | Acc];
            ({region, _}, Acc) ->
                Acc; % internal parameter
            (Elem, Acc) -> [Elem | Acc]
        end,
        [{modu, <<"LORA">>}, {rfch, RFch}, {ipol, true}, {size, byte_size(Data)}, {data, base64:encode(Data)}],
        lists:zip(record_info(fields, txq), tl(tuple_to_list(TxQ)))
    ).

% end of file
