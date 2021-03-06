-module(mpegts_media).
-author('Max Lapshin <max@maxidoors.ru>').
-export([start_link/3]).
-behaviour(gen_server).

-export([ts/1]).

-define(D(X), io:format("DEBUG ~p:~p ~p~n",[?MODULE, ?LINE, X])).

-include_lib("h264/include/h264.hrl").
-include("mpegts.hrl").
-include_lib("erlyvideo/include/video_frame.hrl").

% ems_sup:start_ts_lander("http://localhost:8080").


-record(ts_lander, {
  socket,
  url,
  audio_config = undefined,
  video_config = undefined,
  buffer = <<>>,
  pids,
  clients = [],
  byte_counter = 0
}).

-record(stream_out, {
  pid,
  handler
}).

-record(stream, {
  pid,
  program_num,
  handler,
  consumer,
  type,
  synced = false,
  ts_buffer = [],
  es_buffer = <<>>,
  counter = 0,
  start_pcr = 0,
  pcr = 0,
  start_dts = 0,
  dts = 0,
  start_pts = 0,
  pts = 0,
  video_config = undefined,
  send_audio_config = false,
  timestamp = 0,
  h264
}).

-record(ts_header, {
  payload_start,
  pid,
  pcr = undefined,
  opcr = undefined,
  timestamp,
  payload
}).



%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-export([pat/4, pmt/4, pes/1]).

% {ok, Socket} = gen_tcp:connect("ya.ru", 80, [binary, {packet, http_bin}, {active, false}], 1000),
% gen_tcp:send(Socket, "GET / HTTP/1.0\r\n\r\n"),
% {ok, Reply} = gen_tcp:recv(Socket, 0, 1000),
% Reply.

% {ok, Pid1} = ems_sup:start_ts_lander("http://localhost:8080").

start_link(URL, Type, Opts) ->
  gen_server:start_link(?MODULE, [URL, Type, Opts], []).

init([undefined, Type, _]) ->
  process_flag(trap_exit, true),
  {ok, #ts_lander{pids = [#stream{pid = 0, handler = pat}]}};
  

init([URL, Type, Opts]) when is_binary(URL)->
  init([binary_to_list(URL), Type, Opts]);

init([URL, mpeg_ts_passive, _Opts]) ->
  process_flag(trap_exit, true),
  {ok, #ts_lander{url = URL, pids = [#stream{pid = 0, handler = pat}]}};
  
init([URL, mpeg_ts, _Opts]) ->
  process_flag(trap_exit, true),
  {_, _, Host, Port, Path, Query} = http_uri:parse(URL),
  {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {packet, http_bin}, {active, false}], 1000),
  gen_tcp:send(Socket, "GET "++Path++"?"++Query++" HTTP/1.0\r\n\r\n"),
  ok = inet:setopts(Socket, [{active, once}]),
  
  {ok, #ts_lander{socket = Socket, url = URL, pids = [#stream{pid = 0, handler = pat}]}}.
  
  % io:format("HTTP Request ~p~n", [RequestId]),
  % {ok, #ts_lander{request_id = RequestId, url = URL, pids = [#stream{pid = 0, handler = pat}]}}.
    


%%-------------------------------------------------------------------------
%% @spec (Request, From, State) -> {reply, Reply, State}          |
%%                                 {reply, Reply, State, Timeout} |
%%                                 {noreply, State}               |
%%                                 {noreply, State, Timeout}      |
%%                                 {stop, Reason, Reply, State}   |
%%                                 {stop, Reason, State}
%% @doc Callback for synchronous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------

handle_call({set_socket, Socket}, _From, TSLander) ->
  inet:setopts(Socket, [{active, once}, {packet, raw}]),
  ?D({"MPEG TS received socket"}),
  {reply, ok, TSLander#ts_lander{socket = Socket}};

handle_call({create_player, Options}, _From, #ts_lander{url = URL, clients = Clients} = TSLander) ->
  {ok, Pid} = ems_sup:start_stream_play(self(), Options),
  link(Pid),
  ?D({"Creating media player for", URL, "client", proplists:get_value(consumer, Options), Pid}),
  case TSLander#ts_lander.video_config of
    undefined -> ok;
    VideoConfig -> 
      Pid ! VideoConfig,
      Pid ! h264:metadata(VideoConfig#video_frame.body)
  end,
  case TSLander#ts_lander.audio_config of
    undefined -> ok;
    AudioConfig -> Pid ! AudioConfig
  end,
  {reply, {ok, Pid}, TSLander#ts_lander{clients = [Pid | Clients]}};

handle_call(length, _From, MediaInfo) ->
  {reply, 0, MediaInfo};

handle_call(clients, _From, #ts_lander{clients = Clients} = TSLander) ->
  Entries = lists:map(fun(Pid) -> file_play:client(Pid) end, Clients),
  {reply, Entries, TSLander};

handle_call({set_owner, _}, _From, TSLander) ->
  {reply, ok, TSLander};



handle_call(Request, _From, State) ->
  ?D({"Undefined call", Request, _From}),
  {stop, {unknown_call, Request}, State}.


%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for asyncrous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_cast(_Msg, State) ->
  ?D({"Undefined cast", _Msg}),
  {noreply, State}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for messages sent directly to server's mailbox.
%%      If `{stop, ...}' tuple is returned, the server is stopped and
%%      `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------

handle_info({http, Socket, {http_response, _Version, 200, _Reply}}, TSLander) ->
  inet:setopts(Socket, [{active, once}]),
  {noreply, TSLander};

handle_info({http, Socket, {http_header, _, _Header, _, _Value}}, TSLander) ->
  inet:setopts(Socket, [{active, once}]),
  {noreply, TSLander};


handle_info({http, Socket, http_eoh}, TSLander) ->
  inet:setopts(Socket, [{active, once}, {packet, raw}]),
  {noreply, TSLander};

handle_info(#video_frame{decoder_config = true, type = audio} = Frame, TSLander) ->
  {noreply, send_frame(Frame, TSLander#ts_lander{audio_config = Frame})};

handle_info(#video_frame{body = Config, decoder_config = true, type = video} = Frame, TSLander) ->
  Lander = send_frame(Frame, TSLander#ts_lander{video_config = Frame}),
  send_frame(h264:metadata(Config), Lander),
  {noreply, Lander};

handle_info(#video_frame{} = Frame, TSLander) ->
  {noreply, send_frame(Frame, TSLander)};


handle_info({'EXIT', Client, _Reason}, #ts_lander{clients = Clients} = TSLander) ->
  {noreply, TSLander#ts_lander{clients = lists:delete(Client, Clients)}};

handle_info({tcp, Socket, Bin}, #ts_lander{buffer = <<>>, byte_counter = Counter} = TSLander) ->
  inet:setopts(Socket, [{active, once}]),
  {noreply, synchronizer(Bin, TSLander#ts_lander{byte_counter = Counter + size(Bin)})};

handle_info({tcp, Socket, Bin}, #ts_lander{buffer = Buf, byte_counter = Counter} = TSLander) ->
  inet:setopts(Socket, [{active, once}]),
  {noreply, synchronizer(<<Buf/binary, Bin/binary>>, TSLander#ts_lander{byte_counter = Counter + size(Bin)})};

handle_info({tcp_closed, Socket}, #ts_lander{socket = Socket} = TSLander) ->
  {stop, normal, TSLander#ts_lander{socket = undefined}};
  
handle_info(stop, #ts_lander{socket = Socket} = TSLander) ->
  gen_tcp:close(Socket),
  {stop, normal, TSLander#ts_lander{socket = undefined}};

handle_info(_Info, State) ->
  ?D({"Undefined info", _Info}),
  {noreply, State}.


send_frame(Frame, #ts_lander{clients = Clients} = TSLander) ->
  lists:foreach(fun(Client) -> Client ! Frame end, Clients),
  TSLander.

synchronizer(<<16#47, _:187/binary, 16#47, _/binary>> = Bin, TSLander) ->
  {Packet, Rest} = split_binary(Bin, 188),
  Lander = demux(TSLander, Packet),
  synchronizer(Rest, Lander);

synchronizer(<<_, Bin/binary>>, TSLander) when size(Bin) >= 374 ->
  synchronizer(Bin, TSLander);

synchronizer(Bin, TSLander) ->
  TSLander#ts_lander{buffer = Bin}.


ts(<<16#47, _TEI:1, PayloadStart:1, _:1, Pid:13, _Opt:4, Counter:4, _/binary>> = Packet) ->
  Header = packet_timestamp(adaptation_field(Packet, #ts_header{payload_start = PayloadStart})),
  Header#ts_header{pid = Pid, payload = ts_payload(Packet)}.


demux(#ts_lander{pids = Pids} = TSLander, <<16#47, _:1, PayloadStart:1, _:1, Pid:13, _:4, Counter:4, _/binary>> = Packet) ->
  Header = packet_timestamp(adaptation_field(Packet, #ts_header{payload_start = PayloadStart})),
  case lists:keyfind(Pid, #stream.pid, Pids) of
    #stream{handler = Handler, counter = _OldCounter} = Stream ->
      % Counter = (OldCounter + 1) rem 15,
      % ?D({Handler, Packet}),
      ?MODULE:Handler(ts_payload(Packet), TSLander, Stream#stream{counter = Counter}, Header);
    #stream_out{handler = Handler} ->
      Handler ! {ts_packet, Header, ts_payload(Packet)},
      TSLander;
    false ->
      TSLander
  end.
  
      

ts_payload(<<16#47, _TEI:1, _Start:1, _Priority:1, _Pid:13, _Scrambling:2, 0:1, 1:1, _Counter:4, Payload/binary>>)  -> 
  Payload;

ts_payload(<<16#47, _TEI:1, _Start:1, _Priority:1, _Pid:13, _Scrambling:2, 1:1, 1:1, _Counter:4, 
              AdaptationLength, _AdaptationField:AdaptationLength/binary, Payload/binary>>) -> 
  Payload;

ts_payload(<<16#47, _TEI:1, _Start:1, _Priority:1, _Pid:13, _Scrambling:2, 
              _Adaptation:1, 0:1, _Counter:4, _Payload/binary>>)  ->
  ?D({"Empty payload on pid", _Pid}),
  <<>>.

adaptation_field(<<16#47, _:18, 0:1, _:5, _/binary>>, Header) -> Header;
adaptation_field(<<16#47, _:18, 1:1, _:5, AdaptationLength, AdaptationField:AdaptationLength/binary, _/binary>>, Header) when AdaptationLength > 0 -> 
  parse_adaptation_field(AdaptationField, Header);
  
adaptation_field(_, Header) -> Header.


parse_adaptation_field(<<_Discontinuity:1, _RandomAccess:1, _Priority:1, PCR:1, OPCR:1, _Splice:1, _Private:1, _Ext:1, Data/binary>>, Header) ->
  parse_adaptation_field(Data, PCR, OPCR, Header).

parse_adaptation_field(<<Pcr1:33, Pcr2:9, Rest/bitstring>>, 1, OPCR, Header) ->
  parse_adaptation_field(Rest, 0, OPCR, Header#ts_header{pcr = round((Pcr1 * 300 + Pcr2) / 27000)});

parse_adaptation_field(<<OPcr1:33, OPcr2:9, _Rest/bitstring>>, 0, 1, Header) ->
  Header#ts_header{opcr = round((OPcr1 * 300 + OPcr2) / 27000)};
  
parse_adaptation_field(_, 0, 0, Field) -> Field.


packet_timestamp(#ts_header{pcr = PCR} = Header) when is_integer(PCR) andalso PCR > 0 -> Header#ts_header{timestamp = PCR};
packet_timestamp(#ts_header{opcr = OPCR} = Header) when is_integer(OPCR) andalso OPCR > 0 -> Header#ts_header{timestamp = OPCR};
packet_timestamp(Header) -> Header.


%%%%%%%%%%%%%%%   Program access table  %%%%%%%%%%%%%%

pat(<<_PtField, 0, 2#10:2, 2#11:2, Length:12, _Misc:5/binary, PAT/binary>>, #ts_lander{pids = Pids} = TSLander, _, _) -> % PAT
  ProgramCount = round((Length - 5)/4) - 1,
  % io:format("PAT: ~p programs (~p)~n", [ProgramCount, size(PAT)]),
  Descriptors = extract_pat(PAT, ProgramCount, []),
  TSLander#ts_lander{pids = lists:keymerge(#stream.pid, Pids, Descriptors)}.


extract_pat(<<_CRC32/binary>>, 0, Descriptors) ->
  lists:keysort(#stream.pid, Descriptors);
extract_pat(<<ProgramNum:16, _:3, Pid:13, PAT/binary>>, ProgramCount, Descriptors) ->
  % io:format("Program ~p on pid ~p~n", [ProgramNum, Pid]),
  extract_pat(PAT, ProgramCount - 1, [#stream{handler = pmt, pid = Pid, counter = 0, program_num = ProgramNum} | Descriptors]).




pmt(<<_Pointer, 2, _SectionInd:1, 0:1, 2#11:2, SectionLength:12, 
    ProgramNum:16, _:2, _Version:5, _CurrentNext:1, _SectionNumber,
    _LastSectionNumber, _:3, _PCRPID:13, _:4, ProgramInfoLength:12, 
    ProgramInfo:ProgramInfoLength/binary, PMT/binary>>, #ts_lander{pids = Pids} = TSLander, _, _) ->
  _SectionCount = round(SectionLength - 13),
  io:format("Program ~p v~p. PCR: ~p~n", [ProgramNum, _Version, _PCRPID]),
  % io:format("Program info: ~p~n", [ProgramInfo]),
  Descriptors = extract_pmt(PMT, []),
  % io:format("Streams: ~p~n", [Descriptors]),
  Descriptors1 = lists:map(fun(#stream{pid = Pid} = Stream) ->
    case lists:keyfind(Pid, #stream.pid, Pids) of
      false ->
        Handler = spawn_link(?MODULE, pes, [Stream#stream{program_num = ProgramNum, consumer = self(), h264 = #h264{}}]),
        ?D({"Starting PID", Pid, Handler}),
        #stream_out{pid = Pid, handler = Handler};
      Other ->
        Other
    end
  end, Descriptors),
  % AllPids = [self() | lists:map(fun(A) -> element(#stream_out.handler, A) end, Descriptors1)],
  % eprof:start(),
  % eprof:start_profiling(AllPids),
  % TSLander#ts_lander{pids = lists:keymerge(#stream.pid, Pids, Descriptors1)}.
  TSLander#ts_lander{pids = Descriptors1}.

extract_pmt(<<StreamType, 2#111:3, Pid:13, _:4, ESLength:12, _ES:ESLength/binary, Rest/binary>>, Descriptors) ->
  ?D({"Pid -> Type", Pid, StreamType}),
  extract_pmt(Rest, [#stream{handler = pes, counter = 0, pid = Pid, type = stream_type(StreamType)}|Descriptors]);
  
extract_pmt(_CRC32, Descriptors) ->
  % io:format("Unknown PMT: ~p~n", [PMT]),
  lists:keysort(#stream.pid, Descriptors).


stream_type(?TYPE_VIDEO_H264) -> video;
stream_type(?TYPE_AUDIO_AAC) -> audio;
stream_type(?TYPE_AUDIO_AAC2) -> audio;
stream_type(Type) -> ?D({"Unknown TS PID type", Type}), unhandled.

pes(#stream{synced = false, pid = Pid} = Stream) ->
  receive
    {ts_packet, #ts_header{payload_start = 0}, _} ->
      ?D({"Not synced pes", Pid}),
      ?MODULE:pes(Stream);
    {ts_packet, #ts_header{payload_start = 1}, Packet} ->
      ?D({"Synced PES", Pid}),
      Stream1 = Stream#stream{synced = true, ts_buffer = [Packet]},
      ?MODULE:pes(Stream1);
    Other ->
      ?D({"Undefined message to pid", Pid, Other})
  end;
  
pes(#stream{synced = true, pid = Pid, ts_buffer = Buf} = Stream) ->
  receive
    {ts_packet, #ts_header{payload_start = 0}, Packet} ->
      Stream1 = Stream#stream{synced = true, ts_buffer = [Packet | Buf]},
      ?MODULE:pes(Stream1);
    {ts_packet, #ts_header{payload_start = 1} = Header, Packet} ->
      PES = list_to_binary(lists:reverse(Buf)),
      % ?D({"Decode PES", Pid, size(Stream#stream.es_buffer), length(Stream#stream.ts_buffer)}),
      % ?D({"Decode PES", Pid, length(element(2, process_info(self(), binary)))}),
      % ?D({"Decode PES", Pid, length(Stream#stream.parameters)}),
      Stream1 = pes_packet(PES, Stream, Header),
      Stream2 = Stream1#stream{ts_buffer = [Packet]},
      ?MODULE:pes(Stream2);
    Other ->
      ?D({"Undefined message to pid", Pid, Other})
  end.
    
      
pes_packet(_, #stream{type = unhandled} = Stream, _) -> Stream#stream{ts_buffer = []};

pes_packet(<<1:24, _:5/binary, Length, _PESHeader:Length/binary, Data/binary>> = Packet, #stream{type = audio, es_buffer = Buffer} = Stream, Header) ->
  Stream1 = stream_timestamp(Packet, Stream, Header),
  % ?D({"Audio", Stream1#stream.timestamp, <<Buffer/binary, Data/binary>>}),
  % Stream1;
  decode_aac(Stream1#stream{es_buffer = <<Buffer/binary, Data/binary>>});
  
pes_packet(<<1:24, _:5/binary, Length, _PESHeader:Length/binary, Rest/binary>> = Packet, #stream{es_buffer = Buffer, type = video} = Stream, Header) ->
  % ?D({"Timestamp1", Stream#stream.timestamp, Stream#stream.start_time}),
  Stream1 = stream_timestamp(Packet, Stream, Header),
  % ?D({"Video", Stream1#stream.timestamp, _PESHeader}),
  decode_avc(Stream1#stream{es_buffer = <<Buffer/binary, Rest/binary>>}).


stream_timestamp(<<_:7/binary, 2#00:2, _:6, PESHeaderLength, _PESHeader:PESHeaderLength/binary, _/binary>>, Stream, #ts_header{timestamp = TimeStamp}) when is_integer(TimeStamp) andalso TimeStamp > 0 ->
  % ?D({"No DTS, taking", TimeStamp}),
  normalize_timestamp(Stream#stream{pcr = round(TimeStamp)});

stream_timestamp(<<_:7/binary, 2#11:2, _:6, PESHeaderLength, PESHeader:PESHeaderLength/binary, _/binary>>, Stream, _Header) ->
  <<2#0011:4, Pts1:3, 1:1, Pts2:15, 1:1, Pts3:15, 1:1, 
    2#0001:4, Dts3:3, 1:1, Dts2:15, 1:1, Dts1:15, 1:1, Rest/binary>> = PESHeader,
  DTS = round((Dts1 + (Dts2 bsl 15) + (Dts3 bsl 30))/90),
  PTS = round((Pts1 + (Pts2 bsl 15) + (Pts3 bsl 30))/90),
  % ?D({"Have DTS & PTS", DTS, PTS, Rest}),
  normalize_timestamp(Stream#stream{dts = DTS, pts = PTS});
  

stream_timestamp(<<_:7/binary, 2#10:2, _:6, PESHeaderLength, PESHeader:PESHeaderLength/binary, _/binary>>, Stream, _Header) ->
  <<2#10:4, Pts3:3, 1:1, Pts2:15, 1:1, Pts1:15, 1:1, Rest/binary>> = PESHeader,
  PTS = round((Pts1 + (Pts2 bsl 15) + (Pts3 bsl 30))/90),
  % ?D({"Have ony PTS", PTS, Rest}),
  normalize_timestamp(Stream#stream{dts = PTS, pts = PTS});

% FIXME!!!
% Here is a HUGE hack. VLC give me stream, where are no DTS or PTS, only OPCR, once a second,
% thus I increment timestamp counter on each NAL, assuming, that there is 25 FPS.
% This is very, very wrong, but I really don't know how to calculate it in other way.
stream_timestamp(_, #stream{timestamp = TimeStamp, dts = DTS, pts = PTS} = Stream, _) ->
  Stream#stream{timestamp = TimeStamp + 40, dts = DTS + 40, pts = PTS + 40}.

% normalize_timestamp(Stream) -> Stream;
normalize_timestamp(#stream{start_dts = 0, dts = DTS} = Stream) when is_integer(DTS) andalso DTS > 0 -> 
  Stream#stream{start_dts = DTS, timestamp = 0, dts = 0};
normalize_timestamp(#stream{start_dts = Start, dts = DTS} = Stream) when is_integer(DTS) andalso DTS > 0 -> 
  Stream#stream{timestamp = DTS - Start, dts = 0};
normalize_timestamp(#stream{start_pts = 0, pts = PTS} = Stream) when is_integer(PTS) andalso PTS > 0 -> 
  Stream#stream{start_pts = PTS, timestamp = 0, pts = 0};
normalize_timestamp(#stream{start_pts = Start, pts = PTS} = Stream) when is_integer(PTS) andalso PTS > 0 -> 
  Stream#stream{timestamp = PTS - Start, pts = 0};
normalize_timestamp(#stream{start_pcr = 0, pcr = PCR} = Stream) when is_integer(PCR) andalso PCR > 0 -> 
  Stream#stream{start_pcr = PCR, timestamp = 0, pcr = 0};
normalize_timestamp(#stream{start_pcr = Start, pcr = PCR} = Stream) -> 
  Stream#stream{timestamp = PCR - Start, pcr = 0}.
% normalize_timestamp(Stream) -> Stream.

% <<18,16,6>>
decode_aac(#stream{send_audio_config = false, consumer = Consumer} = Stream) ->
  % Config = <<16#A:4, 3:2, 1:1, 1:1, 0>>,
  Config = <<18,16>>,
  AudioConfig = #video_frame{       
   	type          = audio,
   	decoder_config = true,
		dts           = 0,
		body          = Config,
	  codec_id	    = aac,
	  sound_type	  = stereo,
	  sound_size	  = bit16,
	  sound_rate	  = rate44
	},
	Consumer ! AudioConfig,
  % ?D({"Send audio config", AudioConfig}),
	decode_aac(Stream#stream{send_audio_config = true});
  

decode_aac(#stream{es_buffer = <<_Syncword:12, _ID:1, _Layer:2, 0:1, _Profile:2, _Sampling:4,
                                 _Private:1, _Channel:3, _Original:1, _Home:1, _Copyright:1, _CopyrightStart:1,
                                 _FrameLength:13, _ADTS:11, _Count:2, _CRC:16, Rest/binary>>} = Stream) ->
  send_aac(Stream#stream{es_buffer = Rest});

decode_aac(#stream{es_buffer = <<_Syncword:12, _ID:1, _Layer:2, _ProtectionAbsent:1, _Profile:2, _Sampling:4,
                                 _Private:1, _Channel:3, _Original:1, _Home:1, _Copyright:1, _CopyrightStart:1,
                                 _FrameLength:13, _ADTS:11, _Count:2, Rest/binary>>} = Stream) ->
  % ?D({"AAC", Syncword, ID, Layer, ProtectionAbsent, Profile, Sampling, Private, Channel, Original, Home,
  % Copyright, CopyrightStart, FrameLength, ADTS, Count}),
  % ?D({"AAC", Rest}),
  send_aac(Stream#stream{es_buffer = Rest}).

send_aac(#stream{es_buffer = Data, consumer = Consumer, timestamp = Timestamp} = Stream) ->
  % ?D({"Audio", Timestamp, Data}),
  AudioFrame = #video_frame{       
    type          = audio,
    dts           = Timestamp,
    body          = Data,
	  codec_id	    = aac,
	  sound_type	  = stereo,
	  sound_size	  = bit16,
	  sound_rate	  = rate44
  },
  Consumer ! AudioFrame,
  Stream#stream{es_buffer = <<>>}.
  

decode_avc(#stream{es_buffer = <<16#000001:24, _/binary>>} = Stream) ->
  find_nal_end(Stream, 3);
  
decode_avc(#stream{es_buffer = Data} = Stream) ->
  % io:format("PES ~p ~p ~p ~p, ~p, ~p~n", [StreamId, _DataAlignmentIndicator, _PesPacketLength, PESHeaderLength, PESHeader, Rest]),
  % io:format("PES ~p ~p ~p ~p, ~p, ~p~n", [StreamId, _DataAlignmentIndicator, _PesPacketLength, PESHeaderLength, PESHeader, Rest]),
  Offset1 = nal_unit_start_code_finder(Data, 0) + 3,
  find_nal_end(Stream, Offset1).
  
find_nal_end(Stream, false) ->  
  Stream;
  
find_nal_end(#stream{es_buffer = Data} = Stream, Offset1) ->
  Offset2 = nal_unit_start_code_finder(Data, Offset1+3),
  extract_nal(Stream, Offset1, Offset2).

extract_nal(Stream, _, false) ->
  Stream;
  
extract_nal(#stream{es_buffer = Data, consumer = Consumer, timestamp = Timestamp, h264 = H264} = Stream, Offset1, Offset2) ->
  Length = Offset2-Offset1,
  <<_:Offset1/binary, NAL:Length/binary, Rest1/binary>> = Data,
  % ?D({"Found NAL", Offset1, Offset2, NAL}),
  {H264_1, Frames} = h264:decode_nal(NAL, H264),
  lists:foreach(fun(Frame) ->
    Consumer ! Frame#video_frame{dts = Timestamp}
  end, Frames),
  decode_avc(Stream#stream{es_buffer = Rest1, h264 = H264_1}).

nal_unit_start_code_finder(Bin, Offset) ->
  case Bin of
    <<_:Offset/binary, Rest/binary>> -> find_nal_start_code(Rest, Offset);
    _ -> false
  end.

find_nal_start_code(<<16#000001:24, _/binary>>, Offset) -> Offset;
find_nal_start_code(<<_:1/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 1;
find_nal_start_code(<<_:2/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 2;
find_nal_start_code(<<_:3/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 3;
find_nal_start_code(<<_:4/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 4;
find_nal_start_code(<<_:5/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 5;
find_nal_start_code(<<_:6/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 6;
find_nal_start_code(<<_:7/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 7;
find_nal_start_code(<<_:8/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 8;
find_nal_start_code(<<_:9/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 9;
find_nal_start_code(<<_:10/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 10;
find_nal_start_code(<<_:11/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 11;
find_nal_start_code(<<_:12/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 12;
find_nal_start_code(<<_:13/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 13;
find_nal_start_code(<<_:14/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 14;
find_nal_start_code(<<_:15/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 15;
find_nal_start_code(<<_:16/binary, Rest/binary>>, Offset) -> find_nal_start_code(Rest, Offset+16);
% find_nal_start_code(<<_, Rest/binary>>, Offset) -> find_nal_start_code(Rest, Offset+1);
find_nal_start_code(_, _) -> false.


%%-------------------------------------------------------------------------
%% @spec (Reason, State) -> any
%% @doc  Callback executed on server shutdown. It is only invoked if
%%       `process_flag(trap_exit, true)' is set by the server process.
%%       The return value is ignored.
%% @end
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, _TSLander) ->
  ?D({"TS Lander terminating", _Reason}),
  ok.

%%-------------------------------------------------------------------------
%% @spec (OldVsn, State, Extra) -> {ok, NewState}
%% @doc  Convert process state when code is changed.
%% @end
%% @private
%%-------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
