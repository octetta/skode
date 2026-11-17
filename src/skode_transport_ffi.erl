-module(skode_transport_ffi).
-export([
    udp_open/0,
    udp_open_port/1,
    udp_send/4,
    udp_close/1,
    port_spawn/2,
    port_send/2,
    port_close/1
]).

%% =============================================================================
%% UDP Transport (BEAM)
%% =============================================================================

%% Open an ephemeral UDP client socket configured for binary data.
udp_open() ->
    case gen_udp:open(0, [binary, {active, false}]) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% Open a UDP socket bound to a specific local port.
udp_open_port(Port) ->
    case gen_udp:open(Port, [binary, {active, false}]) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% Send binary or string payload to Host:Port via UDP.
udp_send(Socket, HostBinary, Port, DataBinary) ->
    Host = case is_binary(HostBinary) of
        true -> binary_to_list(HostBinary);
        false -> HostBinary
    end,
    Data = case is_binary(DataBinary) of
        true -> DataBinary;
        false -> unicode:characters_to_binary(DataBinary)
    end,
    case gen_udp:send(Socket, Host, Port, Data) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% Close the UDP socket.
udp_close(Socket) ->
    gen_udp:close(Socket),
    nil.

%% =============================================================================
%% Erlang Port Subprocess Transport (BEAM)
%% =============================================================================

%% Spawn mini-skred or an external engine binary under Erlang Port supervision.
port_spawn(ExecutableBinary, ArgsList) ->
    RawExe = case is_binary(ExecutableBinary) of
        true -> binary_to_list(ExecutableBinary);
        false -> ExecutableBinary
    end,
    Exe = case os:find_executable(RawExe) of
        false -> RawExe;
        Path -> Path
    end,
    Args = [case is_binary(A) of true -> binary_to_list(A); false -> A end || A <- ArgsList],
    try
        Port = open_port({spawn_executable, Exe}, [
            binary,
            use_stdio,
            stderr_to_stdout,
            {args, Args}
        ]),
        {ok, Port}
    catch
        error:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Send a line of Skode text down stdin to the supervised Port.
port_send(Port, DataBinary) ->
    Data = case is_binary(DataBinary) of
        true -> DataBinary;
        false -> unicode:characters_to_binary(DataBinary)
    end,
    try
        Payload = case binary:last(Data) of
            $\n -> Data;
            _ -> <<Data/binary, "\n">>
        end,
        port_command(Port, Payload),
        {ok, nil}
    catch
        error:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Terminate the Port.
port_close(Port) ->
    try
        erlang:port_close(Port)
    catch
        _:_ -> ok
    end,
    nil.
