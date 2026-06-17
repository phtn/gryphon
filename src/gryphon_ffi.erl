-module(gryphon_ffi).
-export([plain_arguments/0, unix_millis/0, monotonic_millis/0, ensure_started/1, halt/1]).

plain_arguments() ->
    [unicode:characters_to_binary(Arg) || Arg <- init:get_plain_arguments()].

unix_millis() ->
    erlang:system_time(millisecond).

monotonic_millis() ->
    erlang:monotonic_time(millisecond).

ensure_started(App) when is_binary(App) ->
    case application:ensure_all_started(binary_to_atom(App, utf8)) of
        {ok, _Started} ->
            {ok, nil};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

halt(Code) ->
    erlang:halt(Code).
