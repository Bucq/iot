%%%-------------------------------------------------------------------
%%% @author ludwikbukowski
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 17. Aug 2015 10:35 AM
%%%-------------------------------------------------------------------
-module(connection_server).
-author("ludwikbukowski").
-behavoiur(gen_server).
-define(NAME, connection_server).
-define(ERROR_LOGGER,my_error_logger).
-define(TIMER,timer).
-define(TIMEOUT,3000).
-include_lib("escalus/include/escalus.hrl").
-include_lib("include/iot_lib.hrl").
%% API
-export([start_link/1, init/1, handle_call/3, handle_info/2, terminate/2, code_change/3]).
-export([connect/0, register_handler/2, unregister_handler/1, get_time/0, time_from_stanza/1, user_spec/5, save_time/0]).

start_link(_) ->
  gen_server:start_link(
    {local, ?NAME},
    connection_server,
    [], []).

init(_) ->
  {ok, {not_connected, dict:new()}}.

% Api
connect() ->
  {ok, Username} = application:get_env(iot,username),
  {ok, Password} = application:get_env(iot,password),
  {ok, Domain} = application:get_env(iot,domain),
  {ok, Host} = application:get_env(iot,host),
  {ok, Resource} = application:get_env(iot,resource),
  gen_server:call(?NAME, {connect, Username, Password, Domain, Host, Resource}).

get_time() ->
   gen_server:call(?NAME, get_time).

save_time() ->
  gen_server:call(?NAME, save_time).

register_handler(HandlerName, Handler) ->
  gen_server:call(?NAME, {register_handler, HandlerName, Handler}).

unregister_handler(HandlerName) ->
  gen_server:call(?NAME, {unregister_handler, HandlerName}).


%% Handle Calls and casts
handle_call({connect, Username, Password, Domain, Host, Resource},_,{SomeClient, Dict}) ->
  Cfg = user_spec(Username, Domain, Host, Password, Resource),
  MergedConf = merge_props([], Cfg),
  case escalus_connection:start(MergedConf) of
    {ok, Client, _, _} ->
      send_presence_available(Client),
      receive
        {stanza, _, Stanza} -> case escalus_pred:is_presence(Stanza) of
                 true ->
                   {reply, {Client, Dict}, {Client, Dict}};
                 _ ->
                   {stop, {connection_wrong_receive, Stanza}, {SomeClient, Dict}}
               end
        end;
    _ ->
   %   ?ERROR_LOGGER:log_error({connection_server,"I cannot connect to server"}),
      {stop, cannot_connect, {SomeClient, Dict}}
  end;

handle_call({register_handler, HandlerName, Handler}, _, {Client, Handlers}) ->
  NewHandlers = dict:append(HandlerName, Handler, Handlers),
  {reply, registered , {Client, NewHandlers}};

handle_call({unregister_handler, HandlerName}, _, {Client, Handlers}) ->
  case dict:find(HandlerName, Handlers) of
    error ->
    {reply, not_found,{Client, Handlers}};
    _ ->
      NewHandlers = dict:erase(HandlerName, Handlers),
      {reply, unregistered, {Client, NewHandlers}}
  end;

handle_call(get_time, _, {Client, Handlers}) ->
  {ok, Username} = application:get_env(iot,username),
  {ok, Domain} = application:get_env(iot,domain),
  {ok, Host} = application:get_env(iot,host),
  HalfJid = <<Username/binary, <<"@">>/binary>>,
  FullJid = <<HalfJid/binary,Domain/binary>>,
  Stanza = ?TIME_STANZA(FullJid, Host),
  escalus:send(Client, Stanza),
  receive
    {stanza, _, Reply} ->
      ResponseTime = time_from_stanza(Reply),
      {reply, ResponseTime, {Client, Handlers}}
    after
      ?TIMEOUT ->
        {reply, timeout, {Client, Handlers}}
  end;

handle_call(save_time, _, Data) ->
  {reply,{Utc, Tzo}, State} = ?MODULE:handle_call(get_time, self(), Data),          %% I know Its ugly one. Id like to change it somehow
  os_functions:change_time(Tzo, Utc),
  {reply, {changed, Utc, Tzo}, State}.

handle_info({stanza, _, Stanza}, {Client, Handlers}) ->
  ReturnedAcc = handle_stanza(Stanza, Handlers),                      %%I Should restore it somewhere
  {noreply, {Client, Handlers}}.

%% Other
terminate(_, _) ->
  ok.

code_change(_, _, _) ->
  error(not_implemented).




%% Internal functions
user_spec(Username, Domain, Host ,Password, Resource) ->
  [ {username, Username},
    {server, Domain},
    {host, Host},
    {password, Password},
    {carbons, false},
    {stream_management, false},
    {resource, Resource}
  ].


merge_props(New, Old) ->
  lists:foldl(fun({K, _}=El, Acc) ->
    lists:keystore(K, 1, Acc, El)
  end, Old, New).

send_presence_available(Client) ->
  Pres = escalus_stanza:presence(<<"available">>),
  escalus_connection:send(Client, Pres).

handle_stanza(Stanza, Handlers) ->
  dict:fold(fun(_, Handler, Acc) -> [(hd(Handler))(Stanza)] ++ Acc end, [], Handlers).

time_from_stanza(Stanza = #xmlel{name = <<"iq">>, attrs = _, children = [Child]}) ->
    escalus_pred:is_iq_result(Stanza),
    escalus_pred:is_iq_with_ns(?NS_TIME,Stanza),
    case Child of
    #xmlel{name = <<"time">>, attrs = _, children = Times} ->
      case Times of
      [#xmlel{name = <<"tzo">>, attrs = _, children = [#xmlcdata{content = Tzo}]},
        #xmlel{name = <<"utc">>, attrs = _, children = [#xmlcdata{content = Utc}]} ] ->
        {Tzo, Utc};
        _ -> no_timezone
      end;
        _ -> wrong_stanza
    end;
% Received some other stanza than expected, so im waiting for MY time stanza. Looping and flushing all stanzas other than mine
time_from_stanza(Some) ->
  receive
    {stanza, _, NewStanza} ->
      time_from_stanza(NewStanza);
    _ ->
     % ?ERROR_LOGGER:log_error({connection_server, "I was waiting for time stanza but received not stanza"}),
      erlang:exit({wrong_received_stanza, Some})
  after ?TIMEOUT ->
    %?ERROR_LOGGER:log_error({connection_server, "I was waiting for time stanza, but never received one!"}),
    erlang:exit(timeout)
  end.



