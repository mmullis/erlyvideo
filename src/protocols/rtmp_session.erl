%%%---------------------------------------------------------------------------------------
%%% @author     Roberto Saccon <rsaccon@gmail.com> [http://rsaccon.com]
%%% @author     Stuart Jackson <simpleenigmainc@gmail.com> [http://erlsoft.org]
%%% @author     Luke Hubbard <luke@codegent.com> [http://www.codegent.com]
%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2007 Luke Hubbard, Stuart Jackson, Roberto Saccon, 2009 Max Lapshin
%%% @doc        RTMP finite state behavior module
%%% @reference  See <a href="http://erlyvideo.org" target="_top">http://erlyvideo.org</a> for more information
%%% @end
%%%
%%%
%%% The MIT License
%%%
%%% Copyright (c) 2007 Luke Hubbard, Stuart Jackson, Roberto Saccon, 2009 Max Lapshin
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%%
%%%---------------------------------------------------------------------------------------
-module(rtmp_session).
-author('rsaccon@gmail.com').
-author('simpleenigmainc@gmail.com').
-author('luke@codegent.com').
-author('Max Lapshin <max@maxidoors.ru>').
-include("../../include/ems.hrl").
-include_lib("erlyvideo/include/video_frame.hrl").
-include_lib("erlyvideo/include/rtmp_session.hrl").

-behaviour(gen_fsm).

-export([start_link/0, set_socket/2]).

-export([channel_id/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-export([send/2]).

%% FSM States
-export([
  'WAIT_FOR_SOCKET'/2,
  'WAIT_FOR_HANDSHAKE'/2,
  'WAIT_FOR_DATA'/2,
  'WAIT_FOR_DATA'/3]).


-export([create_client/1]).
-export([accept_connection/2, reject_connection/2]).

-export([reply/2, fail/2]).

%%% 
create_client(Socket) ->
  {ok, Pid} = ems_sup:start_rtmp_session(Socket),
  {ok, Pid}.

accept_connection(#rtmp_session{socket = Socket} = Session, #rtmp_funcall{args = [{object, PlayerInfo} | _]} = AMF) ->
  Message = #rtmp_message{channel_id = 2, timestamp = 0, body = <<>>},
  % gen_fsm:send_event(self(), {invoke, AMF#rtmp_funcall{command = 'onBWDone', type = invoke, id = 2, stream_id = 0, args = [null]}}),
  rtmp_socket:send(Socket, Message#rtmp_message{type = window_size, body = ?RTMP_WINDOW_SIZE}),
  rtmp_socket:send(Socket, Message#rtmp_message{type = bw_peer, body = ?RTMP_WINDOW_SIZE}),
  % rtmp_socket:send(Socket, Message#rtmp_message{type = stream_begin}),
  rtmp_socket:setopts(Socket, [{chunk_size, ?RTMP_PREF_CHUNK_SIZE}]),
  
  AMFVersion = case lists:keyfind(objectEncoding, 1, PlayerInfo) of
    {objectEncoding, 0.0} -> 0;
    {objectEncoding, 3.0} -> 3;
    {objectEncoding, _N} -> 
      error_logger:error_msg("Warning! Cannot work with clients, using not AMF0/AMF3 encoding.
      Assume _connection.objectEncoding = ObjectEncoding.AMF0; in your flash code is used version ~p~n", [_N]),
      throw(invalid_amf3_encoding);
    _ -> 0
  end,
  
  
  ConnectObj = [{fmsVer, <<?ERLYINFO>>}, {capabilities, 31}],
  StatusObj = [{level, <<"status">>}, 
               {code, <<?NC_CONNECT_SUCCESS>>},
               {description, <<"Connection succeeded.">>},
               {objectEncoding, AMFVersion}],
  reply(Socket, AMF#rtmp_funcall{args = [{object, ConnectObj}, {object, StatusObj}]}),
  rtmp_socket:setopts(Socket, [{amf_version, AMFVersion}]),
  Session.


reject_connection(#rtmp_session{socket = Socket} = Session, AMF) ->
  ConnectObj = [{fmsVer, <<?ERLYINFO>>}, {capabilities, 31}],
  StatusObj = [{level, <<"status">>}, 
               {code, <<?NC_CONNECT_REJECTED>>},
               {description, <<"Connection rejected.">>}],
  reply(Socket, AMF#rtmp_funcall{args = [{object, ConnectObj}, {object, StatusObj}]}),
  gen_fsm:send_event(self(), exit),
  Session.
  
  
reply(#rtmp_session{socket = Socket}, AMF) ->
  rtmp_socket:invoke(Socket, AMF#rtmp_funcall{command = '_result', type = invoke});
reply(Socket, AMF) when is_pid(Socket) ->
  rtmp_socket:invoke(Socket, AMF#rtmp_funcall{command = '_result', type = invoke}).


fail(#rtmp_session{socket = Socket}, AMF) ->
  rtmp_socket:invoke(Socket, AMF#rtmp_funcall{command = '_error', type = invoke}).

  
%%%------------------------------------------------------------------------
%%% API
%%%------------------------------------------------------------------------

start_link() ->
  gen_fsm:start_link(?MODULE, [], []).

set_socket(Pid, Socket) when is_pid(Pid) ->
  gen_fsm:send_event(Pid, {socket_ready, Socket}).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%% @private
%%-------------------------------------------------------------------------
init([]) ->
  process_flag(trap_exit, true),
  random:seed(now()),
  {ok, 'WAIT_FOR_SOCKET', #rtmp_session{streams = array:new()}}.


send(Session, Message) ->
  % case process_info(Session, message_queue_len) of
  %   {message_queue_len, Length} when Length > 100 ->
  %     % ?D({"Session is too slow in consuming messages", Session, Length}),
  %     ok;
  %   _ -> ok
  % end,
  Session ! Message.
  


%%-------------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------
'WAIT_FOR_SOCKET'({socket_ready, RTMP}, State) when is_pid(RTMP) ->
  {address, {IP, Port}} = rtmp_socket:getopts(RTMP, address),
  Addr = lists:flatten(io_lib:format("~p.~p.~p.~p", erlang:tuple_to_list(IP))),
  {next_state, 'WAIT_FOR_HANDSHAKE', State#rtmp_session{socket = RTMP, addr = Addr, port = Port}};


    
'WAIT_FOR_SOCKET'(Other, State) ->
  error_logger:error_msg("State: 'WAIT_FOR_SOCKET'. Unexpected message: ~p\n", [Other]),
  {next_state, 'WAIT_FOR_SOCKET', State}.

'WAIT_FOR_HANDSHAKE'(timeout, #rtmp_session{host = Host, user_id = UserId, addr = IP} = State) ->
  ems_log:error(Host, "TIMEOUT ~p ~p", [UserId, IP]),
  {stop, normal, State}.

%% Notification event coming from client

'WAIT_FOR_DATA'(exit, State) ->
  {stop, normal, State};

'WAIT_FOR_DATA'(#rtmp_message{} = Message, State) ->
  rtmp_socket:send(State#rtmp_session.socket, Message),
  {next_state, 'WAIT_FOR_DATA', State};

'WAIT_FOR_DATA'(Message, #rtmp_session{host = Host} = State) ->
  case ems:try_method_chain(Host, 'WAIT_FOR_DATA', [Message, State]) of
    {unhandled} ->
		  ?D({"Ignoring message:", Message}),
      {next_state, 'WAIT_FOR_DATA', State};
    Reply -> Reply
  end.

'WAIT_FOR_DATA'(info, _From, #rtmp_session{addr = {IP1, IP2, IP3, IP4}, port = Port} = State) ->
  {reply, {io_lib:format("~p.~p.~p.~p", [IP1, IP2, IP3, IP4]), Port, self()}, 'WAIT_FOR_DATA', State};
  
'WAIT_FOR_DATA'(Data, _From, State) ->
	io:format("~p Ignoring data: ~p\n", [self(), Data]),
  {next_state, 'WAIT_FOR_DATA', State}.
    
    
% send(#rtmp_session{server_chunk_size = ChunkSize} = State, {#channel{} = Channel, Data}) ->
%   Packet = rtmp:encode(Channel#channel{chunk_size = ChunkSize}, Data),
%   % ?D({"Channel", Channel#channel.type, Channel#channel.timestamp, Channel#channel.length}),
%   send_data(State, Packet).
	

handle_rtmp_message(State, #rtmp_message{type = invoke, body = AMF}) ->
  #rtmp_funcall{command = CommandBin} = AMF,
  Command = binary_to_atom(CommandBin, utf8),
  call_function(ems:check_app(State, Command, 2), State, AMF#rtmp_funcall{command = Command});
  
handle_rtmp_message(#rtmp_session{streams = Streams} = State, 
   #rtmp_message{type = Type, stream_id = StreamId, body = Body, timestamp = Timestamp}) when (Type == video) or (Type == audio) or (Type == metadata) or (Type == metadata3) ->
  Recorder = array:get(StreamId, Streams),
  
  Frame = ems_flv:decode(#video_frame{dts = Timestamp, type = Type}, Body),
  stream_media:publish(Recorder, Frame),
  State;

handle_rtmp_message(State, #rtmp_message{type = shared_object, body = SOEvent}) ->
  #so_message{name = Name, persistent = Persistent} = SOEvent,
  {NewState, Object} = find_shared_object(State, Name, Persistent),
  shared_object:message(Object, SOEvent),
  NewState;

handle_rtmp_message(#rtmp_session{streams = Streams} = State, #rtmp_message{stream_id = StreamId, type = buffer_size, body = BufferSize}) ->
  case array:get(StreamId, Streams) of
    Player when is_pid(Player) -> Player ! {client_buffer, BufferSize};
    _ -> ok
  end,
  State;

handle_rtmp_message(State, #rtmp_message{type = pong}) -> State;
handle_rtmp_message(State, #rtmp_message{type = ping}) -> State;
handle_rtmp_message(State, #rtmp_message{type = ack_read}) -> State;
handle_rtmp_message(State, #rtmp_message{type = window_size}) -> State;
handle_rtmp_message(State, #rtmp_message{type = chunk_size}) -> State;
handle_rtmp_message(State, #rtmp_message{type = broken_meta}) -> State;

handle_rtmp_message(State, Message) ->
  ?D({"RTMP", Message#rtmp_message.type}),
  State.


find_shared_object(#rtmp_session{host = Host, cached_shared_objects = Objects} = State, Name, Persistent) ->
  case lists:keysearch(Name, 1, Objects) of
    false ->
      Object = shared_objects:open(Host, Name, Persistent),
      NewObjects = lists:keystore(Name, 1, Objects, {Name, Object}),
      {State#rtmp_session{cached_shared_objects = NewObjects}, Object};
    {value, {Name, Object}} ->
      {State, Object}
  end.

call_function(unhandled, #rtmp_session{host = Host, addr = IP} = State, #rtmp_funcall{command = Command, args = Args}) ->
  ems_log:error(Host, "Client ~p requested unknown function ~p(~p)~n", [IP, Command, Args]),
  State;

call_function(App, #rtmp_session{} = State, #rtmp_funcall{command = connect, args = [{object, PlayerInfo} | _]} = AMF) ->
  URL = proplists:get_value(tcUrl, PlayerInfo),
  {ok, UrlRe} = re:compile("(.*)://([^/]+)/?(.*)$"),
  {match, [_, _Proto, HostName, Path]} = re:run(URL, UrlRe, [{capture, all, binary}]),
  Host = ems:host(HostName),
  
	NewState1 =	State#rtmp_session{player_info = PlayerInfo, host = Host, path = Path},

	App:connect(NewState1, AMF);

call_function(App, State, #rtmp_funcall{command = Command} = AMF) ->
	App:Command(State, AMF).
  % try
  %   App:Command(AMF, State)
  % catch
  %   _:login_failed ->
  %     throw(login_failed);
  %   What:Error ->
  %     error_logger:error_msg("Command failed: ~p:~p(~p, ~p):~n~p:~p~n~p~n", [App, Command, AMF, State, What, Error, erlang:get_stacktrace()]),
  %     % apps_rtmp:fail(Id, [null, lists:flatten(io_lib:format("~p", [Error]))]),
  %     State
  % end.

	
%%-------------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------
handle_event(Event, StateName, StateData) ->
  {stop, {StateName, undefined_event, Event}, StateData}.


%%-------------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%% @private
%%-------------------------------------------------------------------------

handle_sync_event(Event, _From, StateName, StateData) ->
  io:format("TRACE ~p:~p ~p~n",[?MODULE, ?LINE, got_sync_request2]),
  {stop, {StateName, undefined_event, Event}, StateData}.

%%-------------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------
handle_info({rtmp, _Socket, disconnect}, _StateName, #rtmp_session{host = Host, addr=Addr, user_id = UserId} = StateData) ->
  ems_log:access(Host, "DISCONNECT ~p ~p", [Addr, UserId]),
  {stop, normal, StateData};

handle_info({rtmp, Socket, #rtmp_message{} = Message}, StateName, State) ->
  State1 = handle_rtmp_message(State, Message),
  State2 = flush_reply(State1),
  % [{message_queue_len, Messages}, {memory, Memory}] = process_info(self(), [message_queue_len, memory]),
  % io:format("messages=~p,memory=~p~n", [Messages, Memory]),
  rtmp_socket:setopts(Socket, [{active, once}]),
  {next_state, StateName, State2};
  
handle_info({rtmp, Socket, connected}, 'WAIT_FOR_HANDSHAKE', State) ->
  % {ok, PidRe} = re:compile("<0\\.(\\d+)\\.0>"),
  % {match, [_, Self]} = re:run(pid_to_list(self()), PidRe, [{capture, all, list}]),
  % {match, [_, Sock]} = re:run(pid_to_list(Socket), PidRe, [{capture, all, list}]),
  % io:format("eprof:start_profiling([pid(0,~s,0),pid(0,~s,0)]).~n", [Self, Sock]),
  rtmp_socket:setopts(Socket, [{active, once}]),
  {next_state, 'WAIT_FOR_DATA', State};

handle_info({rtmp, _Socket, timeout}, _StateName, #rtmp_session{host = Host, user_id = UserId, addr = IP} = State) ->
  ems_log:error(Host, "TIMEOUT ~p ~p ~p", [_Socket, UserId, IP]),
  {stop, normal, State};
  
handle_info({'EXIT', Socket, _Reason}, _StateName, #rtmp_session{socket = Socket} = State) ->
  {stop, normal, State};

handle_info({'EXIT', PlayerPid, _Reason}, StateName, #rtmp_session{socket = Socket, streams = Streams} = State) ->
  case find_stream(Streams, array:size(Streams), 1, PlayerPid) of
    undefined -> 
      {next_state, StateName, State};
    StreamId ->
      ?D({"Play complete on", StreamId}),
      rtmp_socket:status(Socket, StreamId, <<?NS_PLAY_STOP>>),
      rtmp_socket:status(Socket, StreamId, <<?NS_PLAY_COMPLETE>>),
      NewStreams = array:reset(StreamId, Streams),
      {next_state, StateName, State#rtmp_session{streams = NewStreams}}
  end;

handle_info({'EXIT', Pid, _Reason}, StateName, StateData) ->
  ?D({"Died child", Pid, _Reason}),
  {next_state, StateName, StateData};

handle_info({Port, {data, _Line}}, StateName, State) when is_port(Port) ->
  % No-op. Just child program
  {next_state, StateName, State};

handle_info(#video_frame{type = Type, stream_id=StreamId,dts = DTS} = Frame, 'WAIT_FOR_DATA', State) ->
  Message = #rtmp_message{
    channel_id = channel_id(Type, StreamId), 
    timestamp = DTS,
    type = Type,
    stream_id = StreamId,
    body = ems_flv:encode(Frame)},
	rtmp_socket:send(State#rtmp_session.socket, Message),
  {next_state, 'WAIT_FOR_DATA', State};

handle_info(#rtmp_message{} = Message, StateName, State) ->
  rtmp_socket:send(State#rtmp_session.socket, Message),
  {next_state, StateName, State};

handle_info(_Info, StateName, StateData) ->
  ?D({"Some info handled", _Info, StateName, StateData}),
  {next_state, StateName, StateData}.


find_stream(Streams, Size, StreamId, Stream) when StreamId < Size ->
  case array:get(StreamId, Streams) of
    Stream -> StreamId;
    _Other -> find_stream(Streams, Size, StreamId+1, Stream)
  end;
  
find_stream(_, _, _, _) -> undefined.

flush_reply(State) ->
  receive
    #rtmp_message{} = Message ->
      rtmp_socket:send(State#rtmp_session.socket, Message),
      flush_reply(State)
    after
      0 -> State
  end.

%%-------------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, _StateName, #rtmp_session{socket=Socket, streams = Streams} = State) ->
  lists:foreach(fun(Player) when is_pid(Player) -> Player ! exit;
                   (_) -> ok end, array:sparse_to_list(Streams)),

  lists:foreach(fun(Player) when is_pid(Player) -> (catch erlang:exit(Player));
                   (_) -> ok end, array:sparse_to_list(Streams)),
  ems:call_modules(logout, [State]),
  (catch rtmp_listener:logout()),
  (catch gen_tcp:close(Socket)),
  ok.


%%-------------------------------------------------------------------------
%% Func: code_change/4
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState, NewStateData}
%% @private
%%-------------------------------------------------------------------------
code_change(OldVersion, StateName, #rtmp_session{host = Host} = State, Extra) ->
  plugins_code_change(OldVersion, StateName, State, Extra, ems:get_var(applications, Host, [])).

plugins_code_change(_OldVersion, StateName, State, _Extra, []) -> {ok, StateName, State};

plugins_code_change(OldVersion, StateName, State, Extra, [Module | Modules]) -> 
  case ems:respond_to(Module, code_change, 4) of
    true ->
      error_logger:info_msg("Code change in module ~p~n", [Module]),
      {ok, NewStateName, NewState} = Module:code_change(OldVersion, StateName, State, Extra);
    _ ->
      {NewStateName, NewState} = {StateName, State}
  end,
  plugins_code_change(OldVersion, NewStateName, NewState, Extra, Modules).



channel_id(metadata, StreamId) -> 3 + StreamId;
channel_id(video, StreamId) -> 4 + StreamId;
channel_id(audio, StreamId) -> 5 + StreamId.




