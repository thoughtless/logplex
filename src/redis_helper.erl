%% Copyright (c) 2010 Jacob Vorreuter <jacob.vorreuter@gmail.com>
%% 
%% Permission is hereby granted, free of charge, to any person
%% obtaining a copy of this software and associated documentation
%% files (the "Software"), to deal in the Software without
%% restriction, including without limitation the rights to use,
%% copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following
%% conditions:
%% 
%% The above copyright notice and this permission notice shall be
%% included in all copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
%% OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
%% HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%% WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
%% OTHER DEALINGS IN THE SOFTWARE.
-module(redis_helper).
-compile(export_all).

-include_lib("logplex.hrl").

%%====================================================================
%% SESSION
%%====================================================================
create_session(Session, Body) when is_binary(Session), is_binary(Body) ->
    redis:q(config_pool, [<<"SETEX">>, Session, <<"360">>, Body]).

lookup_session(Session) when is_binary(Session) ->
    case redis:q(config_pool, [<<"GET">>, Session]) of
        {ok, Data} -> Data;
        Err -> Err
    end.

%%====================================================================
%% CHANNEL
%%====================================================================
channel_index() ->
    case redis:q(config_pool, [<<"INCR">>, <<"channel_index">>]) of
        {ok, ChannelId} -> ChannelId;
        Err -> Err
    end.

create_channel(ChannelName, AppId, Addon) when is_binary(ChannelName), is_integer(AppId), is_binary(Addon) ->
    ChannelId = channel_index(),
    case redis:q(config_pool, [<<"HMSET">>, iolist_to_binary([<<"ch:">>, integer_to_list(ChannelId), <<":data">>]),
            <<"name">>, ChannelName,
            <<"app_id">>, integer_to_list(AppId),
            <<"addon">>, Addon]) of
        {ok, _} -> ChannelId;
        Err -> Err
    end.

delete_channel(ChannelId) when is_integer(ChannelId) ->
    case redis:q(config_pool, [<<"DEL">>, iolist_to_binary([<<"ch:">>, integer_to_list(ChannelId), <<":data">>])]) of
        {ok, 1} -> ok;
        Err -> Err
    end.

update_channel_addon(ChannelId, Addon) when is_integer(ChannelId), is_binary(Addon) ->
    case redis:q(config_pool, [<<"HSET">>, iolist_to_binary([<<"ch:">>, integer_to_list(ChannelId), <<":data">>]), <<"addon">>, Addon]) of
        {ok, _} -> ok;
        Err -> Err
    end.

build_push_msg(ChannelId, Length, Msg) when is_integer(ChannelId), is_binary(Length), is_binary(Msg) ->
    Key = iolist_to_binary(["ch:", integer_to_list(ChannelId), ":spool"]),
    iolist_to_binary([
        redis:build_request([<<"LPUSH">>, Key, Msg]),
        redis:build_request([<<"LTRIM">>, Key, <<"0">>, Length])
    ]).

lookup_channels() ->
    lists:flatten(lists:foldl(
        fun ({ok, Key}, Acc) when is_binary(Key) ->
            case string:tokens(binary_to_list(Key), ":") of
                ["ch", ChannelId, "data"] ->
                    case lookup_channel(list_to_integer(ChannelId)) of
                        undefined -> Acc;
                        Channel -> [Channel|Acc]
                    end;
                _ ->
                    Acc
            end;
            (_, Acc) ->
                Acc
        end, [], redis:q(config_pool, [<<"KEYS">>, <<"ch:*:data">>]))).
 
lookup_channel_ids() ->
    lists:flatten(lists:foldl(
        fun({ok, Key}, Acc) ->
            case string:tokens(binary_to_list(Key), ":") of
                ["ch", ChannelId, "data"] ->
                    [list_to_integer(ChannelId)|Acc];
                _ -> Acc
            end
        end, [], redis:q(config_pool, [<<"KEYS">>, <<"ch:*:data">>]))).

lookup_channel(ChannelId) when is_integer(ChannelId) ->
    case redis:q(config_pool, [<<"HGETALL">>, iolist_to_binary([<<"ch:">>, integer_to_list(ChannelId), <<":data">>])]) of
        Fields when is_list(Fields), length(Fields) > 0 ->
            #channel{
                id = ChannelId,
                name = logplex_utils:field_val(<<"name">>, Fields),
                app_id =
                 case logplex_utils:field_val(<<"app_id">>, Fields) of
                     Val when is_binary(Val), size(Val) > 0 ->
                         list_to_integer(binary_to_list(Val));
                     _ -> undefined
                 end,
                addon = logplex_utils:field_val(<<"addon">>, Fields)
            };
        _ ->
            undefined
    end.

%%====================================================================
%% TOKEN
%%====================================================================
create_token(ChannelId, TokenId, TokenName) when is_integer(ChannelId), is_binary(TokenId), is_binary(TokenName) ->
    Res = redis:q(config_pool, [<<"HMSET">>, iolist_to_binary([<<"tok:">>, TokenId, <<":data">>]), <<"ch">>, integer_to_list(ChannelId), <<"name">>, TokenName]),
    case Res of
        {ok, <<"OK">>} -> ok;
        Err -> Err
    end.

delete_token(TokenId) when is_binary(TokenId) ->
    case redis:q(config_pool, [<<"DEL">>, TokenId]) of
        {ok, 1} -> ok;
        Err -> Err
    end.

lookup_token(TokenId) when is_binary(TokenId) ->
    case redis:q(config_pool, [<<"HGETALL">>, iolist_to_binary([<<"tok:">>, TokenId, <<":data">>])]) of
        Fields when is_list(Fields), length(Fields) > 0 ->
            #token{id = TokenId,
                   channel_id = list_to_integer(binary_to_list(logplex_utils:field_val(<<"ch">>, Fields))),
                   name = logplex_utils:field_val(<<"name">>, Fields)
            };
        _ ->
            undefined
    end.

lookup_tokens() ->
    lists:flatten(lists:foldl(
        fun({ok, Key}, Acc) ->
            case string:tokens(binary_to_list(Key), ":") of
                ["tok", TokenId, "data"] ->
                    case lookup_token(list_to_binary(TokenId)) of
                        undefined -> Acc;
                        Token -> [Token|Acc]
                    end;
                _ ->
                    Acc
            end
        end, [], redis:q(config_pool, [<<"KEYS">>, <<"tok:*:data">>]))).

%%====================================================================
%% DRAIN
%%====================================================================
drain_index() ->
    case redis:q(config_pool, [<<"INCR">>, <<"drain_index">>]) of
        {ok, DrainId} -> DrainId;
        Err -> Err
    end.

create_drain(DrainId, ChannelId, Host, Port) when is_integer(DrainId), is_integer(ChannelId), is_binary(Host) ->
    Key = iolist_to_binary([<<"drain:">>, integer_to_list(DrainId), <<":data">>]),
    Res = redis:q(config_pool, [<<"HMSET">>, Key,
        <<"ch">>, integer_to_list(ChannelId),
        <<"host">>, Host] ++
        [<<"port">> || is_integer(Port)] ++
        [integer_to_list(Port) || is_integer(Port)]),
    case Res of
        {ok, <<"OK">>} -> ok;
        Err -> Err
    end.

delete_drain(DrainId) when is_integer(DrainId) ->
    case redis:q(config_pool, [<<"DEL">>, iolist_to_binary([<<"drain:">>, integer_to_list(DrainId), <<":data">>])]) of
        {ok, 1} -> ok;
        Err -> Err
    end.

lookup_drains() ->
    lists:foldl(
        fun({ok, Key}, Acc) ->
            case string:tokens(binary_to_list(Key), ":") of
                ["drain", DrainId, "data"] ->
                    [lookup_drain(list_to_integer(DrainId))|Acc];
                _ -> Acc
            end
        end, [], redis:q(config_pool, [<<"KEYS">>, <<"drain:*:data">>])).

lookup_drain(DrainId) when is_integer(DrainId) ->
    case redis:q(config_pool, [<<"HGETALL">>, iolist_to_binary([<<"drain:">>, integer_to_list(DrainId), <<":data">>])]) of
        Fields when is_list(Fields), length(Fields) > 0 ->
            #drain{
                id = DrainId,
                channel_id = list_to_integer(binary_to_list(logplex_utils:field_val(<<"ch">>, Fields))),
                host = logplex_utils:field_val(<<"host">>, Fields),
                port =
                 case logplex_utils:field_val(<<"port">>, Fields) of
                     <<"">> -> undefined;
                     Val -> list_to_integer(binary_to_list(Val))
                 end
            };
        _ ->
            undefined
    end.
    
%%====================================================================
%% GRID
%%====================================================================
set_node_ex(Node, Ip, Domain) when is_binary(Node), is_binary(Ip), is_binary(Domain) ->
    redis:q(config_pool, [<<"SETEX">>, iolist_to_binary([<<"node:">>, Domain, <<":">>, Node]), <<"60">>, Ip]).

get_nodes(Domain) when is_binary(Domain) ->
    redis:q(config_pool, [<<"KEYS">>, iolist_to_binary([<<"node:">>, Domain, <<":*">>])]).

get_node(Node) when is_binary(Node) ->
    redis:q(config_pool, [<<"GET">>, Node]).

shard_urls() ->
    redis:q(config_pool, [<<"SMEMBERS">>, <<"redis:shard:urls">>]).

%%====================================================================
%% HEALTHCHECK
%%====================================================================
healthcheck() ->
    case redis:q(config_pool, [<<"INCR">>, <<"healthcheck">>]) of
        {ok, Count} -> Count;
        Error -> exit(Error)
    end.

%%====================================================================
%% STATS
%%====================================================================
publish_stats(InstanceName, Json) when is_list(InstanceName), is_binary(Json) ->
    redis:q(config_pool, [<<"PUBLISH">>, iolist_to_binary([<<"stats.">>, InstanceName]), Json]).