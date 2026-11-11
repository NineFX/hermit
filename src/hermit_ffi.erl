-module(hermit_ffi).

-export([run/3, os_family/0, halt/1]).

%% Runs an executable from the PATH in a directory. Returns what the program
%% writes to standard output; its standard error goes straight to the
%% terminal.
run(Executable, Arguments, Directory) ->
    case os:find_executable(unicode:characters_to_list(Executable)) of
        false ->
            {error, {command_not_found, Executable}};
        Path ->
            Port = open_port(
                {spawn_executable, Path},
                [{args, Arguments}, {cd, Directory}, binary, exit_status, use_stdio, hide]
            ),
            collect(Port, [])
    end.

collect(Port, Output) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Data | Output]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Output))};
        {Port, {exit_status, Status}} ->
            {error, {command_failed, Status}}
    end.

os_family() ->
    case os:type() of
        {win32, _} -> windows;
        _ -> unix
    end.

halt(Status) ->
    erlang:halt(Status).
