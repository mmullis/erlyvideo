%%% @author     Max Lapshin <max@maxidoors.ru>
%%% @author     Takuma Mori <mori@sgra.co.jp> [http://www.sgra.co.jp/en/], SGRA Corporation
%%% @copyright  2008 Takuma Mori, 2009 Max Lapshin
%%% @doc        MP4 decoding module, rewritten from RubyIzumi
%%% @reference  See <a href="http://erlyvideo.org/" target="_top">http://erlyvideo.org/</a> for more information
%%% @end
%%%
%%%
%%% Copyright (c) 2009 Max Lapshin
%%%    This program is free software: you can redistribute it and/or modify
%%%    it under the terms of the GNU Affero General Public License as
%%%    published by the Free Software Foundation, either version 3 of the
%%%    License, or any later version.
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

-module(mp4).
-author('Max Lapshin <max@maxidoors.ru>').
-include("../../include/ems.hrl").
-include("../../include/mp4.hrl").
-include_lib("erlyvideo/include/video_frame.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("../../include/media_info.hrl").

-export([init/1, read_frame/2, metadata/1, codec_config/2, seek/2, first/1]).
-export([ftyp/2, moov/2, mvhd/2, trak/2, tkhd/2, mdia/2, mdhd/2, stbl/2, stsd/2, esds/2, avcC/2,
btrt/2, stsz/2, stts/2, stsc/2, stss/2, stco/2, smhd/2, minf/2, ctts/2]).


-export([mp4_desc_length/1]).

-behaviour(gen_format).

codec_config(video, #media_info{video_codec = VideoCodec} = MediaInfo) ->
  Config = decoder_config(video, MediaInfo),
  % ?D({"Video config", Config}),
  #video_frame{       
   	type          = video,
   	decoder_config = true,
		dts           = 0,
		pts           = 0,
		body          = Config,
		frame_type    = keyframe,
		codec_id      = VideoCodec
	};

codec_config(audio, #media_info{audio_codec = AudioCodec} = MediaInfo) ->
  Config = decoder_config(audio, MediaInfo),
  % ?D({"Audio config", aac:decode_config(Config)}),
  #video_frame{       
   	type          = audio,
   	decoder_config = true,
		dts           = 0,
		pts           = 0,
		body          = Config,
	  codec_id	= AudioCodec,
	  sound_type	  = stereo,
	  sound_size	  = bit16,
	  sound_rate	  = rate44
	}.


first(#media_info{frames = FrameTable}) ->
  ets:first(FrameTable).

read_frame(#media_info{frames = FrameTable} = MediaInfo, Key) ->
  [Frame] = ets:lookup(FrameTable, Key),
  #file_frame{offset = Offset, size = Size} = Frame,
  Next = ets:next(FrameTable, Key),
	case read_data(MediaInfo, Offset, Size) of
		{ok, Data, _} -> {video_frame(Frame, Data), Next};
    eof -> done;
    {error, Reason} -> {error, Reason}
  end.
  

read_data(#media_info{device = IoDev} = MediaInfo, Offset, Size) ->
  case file:pread(IoDev, Offset, Size) of
    {ok, Data} ->
      {ok, Data, MediaInfo};
    Else -> Else
  end.
  
seek(FrameTable, Timestamp) ->
  TimestampInt = round(Timestamp),
  Ids = ets:select(FrameTable, ets:fun2ms(fun(#file_frame{id = Id, dts = FrameTimestamp, keyframe = true} = _Frame) when FrameTimestamp =< TimestampInt ->
    {Id, FrameTimestamp}
  end)),
  case lists:reverse(Ids) of
    [Item | _] -> Item;
    _ -> undefined
  end.
  

% read_data(#video_player{cache = Cache, cache_offset = CacheOffset} = Player, Offset, Size) when (CacheOffset =< Offset) and (Offset + Size - CacheOffset =< size(Cache)) ->
%   Seek = Offset - CacheOffset,
%   % ?D({"Cache hit", Offset, Size}),
%   <<_:Seek/binary, Data:Size/binary, Rest/binary>> = Cache,
%   {ok, Data, Player};
% 
% 

% read_data(#video_player{media_info = #media_info{device = IoDev}} = Player, Offset, Size) ->
%   CacheSize = 60000 + Size,
%   case file:pread(IoDev, Offset, CacheSize) of
%     {ok, CacheList} ->
%       Cache = iolist_to_binary(CacheList),
%       <<Data:Size/binary, _/binary>> = Cache,
%       {ok, Data, Player#video_player{cache_offset = Offset, cache = Cache}};
%     Else -> Else
%   end.
%   

video_frame(#file_frame{type = video, dts = DTS, keyframe = Keyframe, pts = PTS}, Data) ->
  #video_frame{
   	type          = video,
		dts           = DTS,
		pts           = PTS,
		body          = Data,
		frame_type    = case Keyframe of
		  true ->	keyframe;
		  _ -> frame
	  end,
		codec_id      = avc
  };  

video_frame(#file_frame{type = audio, dts = DTS}, Data) ->
  #video_frame{       
   	type          = audio,
  	dts           = DTS,
  	body          = Data,
	  codec_id	    = aac,
	  sound_type	  = stereo,
	  sound_size	  = bit16,
	  sound_rate	  = rate44
  }.



init(#media_info{header = undefined} = MediaInfo) -> 
  init(MediaInfo#media_info{header = #mp4_header{}, frames = ets:new(frames, [ordered_set, {keypos, #file_frame.id}])});

init(MediaInfo) -> 
  init(MediaInfo, 0).

init(MediaInfo, Pos) -> 
  case next_atom(#media_info{device = Device} = MediaInfo, Pos) of
    eof -> {ok, MediaInfo};
    {error, Reason} -> {error, Reason};
    {atom, mdat, Offset, Length} ->
      init(MediaInfo, Offset + Length);
    {atom, _AtomName, Offset, 0} -> 
      init(MediaInfo, Offset);
    {atom, AtomName, Offset, Length} -> 
      ?D({"Root atom", AtomName, Length}),
      {ok, AtomData} = file:pread(Device, Offset, Length),
      NewInfo = case ems:respond_to(?MODULE, AtomName, 2) of
        true -> ?MODULE:AtomName(AtomData, MediaInfo);
        false -> ?D({"Unknown atom", AtomName}), MediaInfo
      end,
      init(NewInfo, Offset + Length)
  end.

next_atom(#media_info{device = Device}, Pos) ->
  case file:pread(Device, Pos, 8) of
    {ok, <<AtomLength:32, AtomName/binary>>} when AtomLength >= 8 ->
      % ?D({"Atom", binary_to_atom(AtomName, latin1), Pos, AtomLength}),
      {atom, binary_to_atom(AtomName, utf8), Pos + 8, AtomLength - 8};
    Else -> Else
  end.


  
metadata(#media_info{width = Width, height = Height, seconds = Duration}) -> 
  [{width, Width}, 
   {height, Height}, 
   {duration, Duration}].
  
  
decoder_config(video, #media_info{video_decoder_config = DecoderConfig}) -> DecoderConfig;
decoder_config(audio, #media_info{audio_decoder_config = DecoderConfig}) -> DecoderConfig.



  
parse_atom(<<>>, Mp4Parser) ->
  Mp4Parser;
  
parse_atom(Atom, _) when size(Atom) < 4 ->
  {error, "Invalid atom"};
  
parse_atom(<<AllAtomLength:32, BinaryAtomName:4/binary, AtomRest/binary>>, Mp4Parser) when (size(AtomRest) >= AllAtomLength - 8) ->
  AtomLength = AllAtomLength - 8,
  <<Atom:AtomLength/binary, Rest/binary>> = AtomRest,
  AtomName = binary_to_atom(BinaryAtomName, utf8),
  NewMp4Parser = case ems:respond_to(?MODULE, AtomName, 2) of
    true -> ?MODULE:AtomName(Atom, Mp4Parser);
    false -> ?D({"Unknown atom", AtomName}), Mp4Parser
  end,
  parse_atom(Rest, NewMp4Parser);
  
parse_atom(<<AllAtomLength:32, BinaryAtomName:4/binary, _Rest/binary>>, Mp4Parser) ->
  ?D({"Invalid atom", AllAtomLength, binary_to_atom(BinaryAtomName, utf8), size(_Rest)}),
  Mp4Parser;

parse_atom(<<0:32>>, Mp4Parser) ->
  ?D("NULL atom"),
  Mp4Parser.

  
% FTYP atom
ftyp(<<_Major:4/binary, _Minor:4/binary, _CompatibleBrands/binary>>, MediaInfo) ->
  ?D({"File", _Major, _Minor, ftyp(_CompatibleBrands, [])}),
  % NewParser = Mp4Parser#mp4_header{file_type = binary_to_list(Major), file_types = decode_atom(ftyp, CompatibleBrands, [])},
  MediaInfo;

ftyp(<<>>, BrandList) when is_list(BrandList) ->
  lists:reverse(BrandList);

ftyp(<<Brand:4/binary, CompatibleBrands/binary>>, BrandList) ->
  ftyp(CompatibleBrands, [Brand|BrandList]).
  
% Movie box
moov(Atom, MediaInfo) ->
  parse_atom(Atom, MediaInfo).

% MVHD atom
mvhd(<<0:8, _Flags:3/binary, _CTime:32, _MTime:32, TimeScale:32,
                    Duration:32, _Rest/binary>>, #media_info{} = MediaInfo) ->
  MediaInfo#media_info{timescale = TimeScale, duration = Duration, seconds = Duration/TimeScale}.

% Track box
trak(<<>>, MediaInfo) ->
  MediaInfo;
  
trak(Atom, #media_info{} = MediaInfo) ->
  Track = parse_atom(Atom, #mp4_track{}),
  fill_track_info(MediaInfo, Track).
  

% Track header
tkhd(<<0:8, _Flags:3/binary, _CTime:32, _MTime:32,
                    TrackID:32, _Reserved1:4/binary, 
                    Duration:32, _Reserved2:8/binary,
                    _Layer:16, _AlternateGroup:2/binary,
                    _Volume:2/binary, _Reserved3:2/binary,
                    _Matrix:36/binary, _TrackWidth:4/binary, _TrackHeigth:4/binary>>, Mp4Track) ->
  Mp4Track#mp4_track{track_id = TrackID, duration = Duration}.

% Media box
mdia(Atom, Mp4Track) ->
  parse_atom(Atom, Mp4Track).

% Media header
mdhd(<<0:8, _Flags:24, _Ctime:32, 
                  _Mtime:32, TimeScale:32, Duration:32,
                  _Language:2/binary, _Quality:16>>, #mp4_track{} = Mp4Track) ->
  % ?D({"Timescale:", Duration, extract_language(_Language)}),
  _DecodedLanguate = extract_language(_Language),
  Mp4Track#mp4_track{timescale = TimeScale, duration = Duration};

mdhd(<<1:8, _Flags:24, _Ctime:64, 
                     _Mtime:64, TimeScale:32, Duration:64, 
                     _Language:2/binary, _Quality:16>>, Mp4Track) ->
  % ?D({"Timescale:", Duration, extract_language(_Language)}),
  Mp4Track#mp4_track{timescale = TimeScale, duration = Duration}.
  
% SMHD atom
smhd(<<0:8, _Flags:3/binary, 0:16/big-signed-integer, _Reserve:2/binary>>, Mp4Track) ->
  Mp4Track;

smhd(<<0:8, _Flags:3/binary, _Balance:16/big-signed-integer, _Reserve:2/binary>>, Mp4Track) ->
  Mp4Track.

% Media information
minf(Atom, Mp4Track) ->
  parse_atom(Atom, Mp4Track).

% Sample table box
stbl(Atom, Mp4Track) ->
  parse_atom(Atom, Mp4Track).

% Sample description
stsd(<<0:8, _Flags:3/binary, EntryCount:32, EntryData/binary>>, Mp4Track) ->
  stsd({EntryCount, EntryData}, Mp4Track);

stsd({0, _}, Mp4Track) ->
  Mp4Track;

stsd({_, <<>>}, Mp4Track) ->
  Mp4Track;
  
stsd({_EntryCount, <<_SampleDescriptionSize:32, 
                                  "mp4a", _Reserved:6/binary, _RefIndex:16, 
                                  _Unknown:8/binary, _ChannelsCount:32,
                                  _SampleSize:32, _SampleRate:32,
                                  Atom/binary>>}, Mp4Track) ->
  parse_atom(Atom, Mp4Track#mp4_track{data_format = mp4a});

stsd({_EntryCount, <<_SampleDescriptionSize:32, 
                                  "avc1", _Reserved:6/binary, _RefIndex:16, 
                                  _Unknown1:16/binary, 
                                  Width:16, Height:16,
                                  _HorizRes:32, _VertRes:32,
                                  _FrameCount:16, _CompressorName:32/binary,
                                  _Depth:16, _Predefined:16,
                                  _Unknown:4/binary,
                                  Atom/binary>>}, Mp4Track) ->
  % ?D({"Video size:", Width, Height}),
  parse_atom(Atom, Mp4Track#mp4_track{data_format = avc1, width = Width, height = Height});

stsd({_EntryCount, <<_SampleDescriptionSize:32, 
                                  "s263", _Reserved:6/binary, _RefIndex:16, 
                                  _Unknown1:16/binary, 
                                  Width:16, Height:16,
                                  _HorizRes:32, _VertRes:32,
                                  _FrameCount:16, _CompressorName:32/binary,
                                  _Depth:16, _Predefined:16,
                                  _Unknown:4/binary,
                                  Atom/binary>>}, Mp4Track) ->
  % ?D({"Video size:", Width, Height}),
  parse_atom(Atom, Mp4Track#mp4_track{data_format = s263, width = Width, height = Height});

stsd({_EntryCount,   <<_SampleDescriptionSize:32, 
                                    "samr", _Reserved:2/binary, _RefIndex:16, 
                                    Atom/binary>> = AMR}, Mp4Track) ->
  ?D(AMR),
  parse_atom(Atom, Mp4Track#mp4_track{data_format = samr});



stsd({_EntryCount, <<SampleDescriptionSize:32, DataFormat:4/binary, 
                                 _Reserved:6/binary, _RefIndex:16, EntryData/binary>>}, Mp4Track) 
           when SampleDescriptionSize == size(EntryData) + 16 ->
  NewTrack = Mp4Track#mp4_track{data_format = binary_to_atom(DataFormat, utf8)},
  ?D({"Unknown sample description:", NewTrack#mp4_track.data_format, SampleDescriptionSize, size(EntryData), binary_to_list(EntryData)}),
  NewTrack.
  
% ESDS atom
esds(<<Version:8, _Flags:3/binary, DecoderConfig/binary>>, #mp4_track{data_format = mp4a} = Mp4Track) when Version == 0 ->
  % ?D({"Extracted audio config", DecoderConfig}),
  Mp4Track#mp4_track{decoder_config = esds_tag(DecoderConfig)}.

% avcC atom
avcC(DecoderConfig, #mp4_track{} = Mp4Track) ->
  % ?D({"Extracted video config"}),
  Mp4Track#mp4_track{decoder_config = DecoderConfig}.

btrt(<<_BufferSize:32, _MaxBitRate:32, _AvgBitRate:32>>, #mp4_track{} = Mp4Track) ->
  Mp4Track.

% STSZ atom
stsz(<<_Version:8, _Flags:24, 0:32, SampleCount:32, SampleSizeData/binary>>, Mp4Track) ->
  Mp4Track#mp4_track{sample_sizes = stsz({SampleCount, SampleSizeData}, [])};
  
stsz({0, _}, SampleSizes) ->
  lists:reverse(SampleSizes);

stsz({_, <<>>}, SampleSizes) ->
  lists:reverse(SampleSizes);

stsz({SampleCount, <<Size:32, Rest/binary>>}, SampleSizes) ->
  stsz({SampleCount - 1, Rest}, [Size | SampleSizes]);

stsz({_, <<Rest/binary>>}, SampleSizes) ->
  ?D("Invalid stsz atom"),
  stsz({0, Rest}, SampleSizes).
  

% STTS atom
stts(<<0:8, _Flags:3/binary, EntryCount:32, Rest/binary>>, #mp4_track{} = Mp4Track) ->
  Table = stts({EntryCount, Rest}, []),
  % ?D({"Sample time table", Table}),
  Mp4Track#mp4_track{sample_durations = lists:reverse(Table)};

stts({0, _}, Table) ->
  Table;
  
stts({_, <<>>}, Table) ->
  Table;
  
stts({EntryCount, <<SampleCount:32, SampleDuration:32, Rest/binary>>}, Table) ->
  stts({EntryCount - 1, Rest}, [{SampleCount, SampleDuration} | Table]).
  
% STSC atom
stsc(<<0:8, _Flags:3/binary, EntryCount:32, Rest/binary>>, #mp4_track{} = Mp4Track) ->
  Table = stsc({EntryCount, Rest}, []),
  % ?D({"Sample chunk table", lists:reverse(Table)}),
  Mp4Track#mp4_track{chunk_table = lists:reverse(Table)};

stsc({0, _}, Table) ->
  Table;
  
stsc({_, <<>>}, Table) ->
  Table;
  
stsc({EntryCount, <<FirstChunk:32, SamplesPerChunk:32, SampleID:32, Rest/binary>>}, Table) ->
  stsc({EntryCount - 1, Rest}, [{FirstChunk, SamplesPerChunk, SampleID} | Table]).

% STSS atom
% List of keyframes
stss(<<0:8, _Flags:3/binary, SampleCount:32, Samples/binary>>, #mp4_track{} = Mp4Track) when size(Samples) == SampleCount*4->
  NewTrack = Mp4Track#mp4_track{keyframes = stss(Samples, [])},
  case NewTrack#mp4_track.keyframes of
    [1 | _] ->
      NewTrack#mp4_track{key_offset = 1};
    _ ->
      NewTrack
  end;

stss(<<>>, SampleList) ->
  lists:reverse(SampleList);
  
stss(<<Sample:32, Rest/binary>>, SampleList) ->
  stss(Rest, [Sample | SampleList]).

% CTTS atom, list of B-Frames offsets
ctts(<<0:32, Count:32, CTTS/binary>>, Mp4Track) ->
  Track = read_ctts(CTTS, Count, Mp4Track),
  ?D({"CTTS atom", Count, length(Track#mp4_track.composition_offsets)}),
  Track.
  

read_ctts(<<>>, 0, #mp4_track{composition_offsets = Offsets} = Mp4Track) ->
  Mp4Track#mp4_track{composition_offsets = lists:reverse(Offsets)};

read_ctts(<<Count:32, Offset:32, CTTS/binary>>, OffsetsCount, #mp4_track{composition_offsets = Offsets} = Mp4Track) ->
  % ?D({"CTTS", Count, Offset}),
  read_ctts(CTTS, OffsetsCount - 1, Mp4Track#mp4_track{composition_offsets = add_offsets(Count, Offset, Offsets)}).

add_offsets(0, _, List) -> List;
add_offsets(Count, Offset, List) -> add_offsets(Count - 1, Offset, [Offset | List]).

% STCO atom
% sample table chunk offset
stco(<<0:8, _Flags:3/binary, OffsetCount:32, Offsets/binary>>, #mp4_track{} = Mp4Track) when size(Offsets) == OffsetCount*4 ->
  Mp4Track#mp4_track{chunk_offsets = stco(Offsets, [])};

stco(<<>>, OffsetList) ->
  lists:reverse(OffsetList);
  
stco(<<Offset:32, Rest/binary>>, OffsetList) ->
  stco(Rest, [Offset | OffsetList]).


extract_language(<<L1:5, L2:5, L3:5, _:1>>) ->
  [L1+16#60, L2+16#60, L3+16#60].


% Internal structure to parse all moov data, untill it reaches mp4_frame table
-record(mp4_frames, {
  data_format,
  timescale,
  index = 1,
  dts = 0,
  chunk_table = [],
  chunk_offsets = [],
  keyframes = [],
  sample_sizes = [],
  durations = [],
  composition_offsets = [], % ctts Composition offsets for B-frames
  duration = 0
}).


fill_track_info(MediaInfo, #mp4_track{data_format = avc1, decoder_config = DecoderConfig, width = Width, height = Height} = Track) ->
  calculate_sample_offsets(MediaInfo#media_info{video_decoder_config = DecoderConfig, width = Width, height = Height}, Track);



fill_track_info(MediaInfo, #mp4_track{data_format = mp4a, decoder_config = DecoderConfig} = Track) ->
  calculate_sample_offsets(MediaInfo#media_info{audio_decoder_config = DecoderConfig}, Track);
  
fill_track_info(MediaInfo, #mp4_track{data_format = Unknown}) ->
  ?D({"Uknown data format", Unknown}),
  MediaInfo.
  


next_duration(#mp4_frames{durations = []}) ->
  {error};

next_duration(#mp4_frames{durations = [{0, _} | Durations]} = FrameReader) ->
  next_duration(FrameReader#mp4_frames{durations = Durations});

next_duration(#mp4_frames{durations = [{DurationCount, Duration} | Durations], duration = TotalDuration} = FrameReader) ->
  {TotalDuration, FrameReader#mp4_frames{durations = [{DurationCount - 1, Duration} | Durations], duration = TotalDuration + Duration}}.

next_composition_offset(#mp4_frames{composition_offsets = []} = FrameReader) ->
  {0, FrameReader};
next_composition_offset(#mp4_frames{composition_offsets = [Offset|Offsets]} = FrameReader) ->
  {Offset, FrameReader#mp4_frames{composition_offsets = Offsets}}.
  

chunk_samples_count(#mp4_frames{chunk_table = [{_, SamplesInChunk, _}]} = FrameReader) ->
  {SamplesInChunk, FrameReader};
  
chunk_samples_count(#mp4_frames{chunk_table = [{FirstChunk, _, _} | [{NextChunk, NextSamplesInChunk, SampleId} | ChunkTable]]} = FrameReader) when FirstChunk == NextChunk ->
  {NextSamplesInChunk, FrameReader#mp4_frames{chunk_table = [{NextChunk + 1, NextSamplesInChunk, SampleId} | ChunkTable]}};

chunk_samples_count(#mp4_frames{chunk_table = [{FirstChunk, SamplesInChunk, SampleId} | ChunkTable]} = FrameReader) ->
  {SamplesInChunk, FrameReader#mp4_frames{chunk_table = [{FirstChunk + 1, SamplesInChunk, SampleId} | ChunkTable]}}.

  
calculate_samples_in_chunk(_FrameTable, _SampleOffset, 0, #mp4_frames{} = FrameReader) ->
  FrameReader;

calculate_samples_in_chunk(FrameTable, SampleOffset, SamplesInChunk, 
  #mp4_frames{index = Index, data_format = DataFormat, keyframes = Keyframes, timescale = Timescale,
    sample_sizes = [SampleSize | SampleSizes]} = FrameReader) ->
  % add dts field
  {Dts, FrameReader1} = next_duration(FrameReader),
  {CompositionOffset, FrameReader2} = next_composition_offset(FrameReader1),
  TimestampMS = round(Dts * 1000 / Timescale),
  CompositionTime = round(CompositionOffset * 1000 / Timescale),
  % ?D({"Comp", CompositionOffset, Timescale, CompositionTime}),
  {FrameType, Id} = case DataFormat of
    avc1 -> {video, TimestampMS*3 + 1 + 3};
    mp4a -> {audio, TimestampMS*3 + 2 + 3}
  end,
  Frame = #file_frame{id = Id, dts = TimestampMS, type = FrameType, offset = SampleOffset, size = SampleSize, keyframe = lists:member(Index, Keyframes), pts = TimestampMS + CompositionTime},
  % ~D([Id, TimestampMS, SampleOffset, SampleSize, Dts, lists:member(Index, Keyframes)]),
  ets:insert(FrameTable, Frame),
  FrameReader3 = FrameReader2#mp4_frames{sample_sizes = SampleSizes, index = Index + 1},
  calculate_samples_in_chunk(FrameTable, SampleOffset + SampleSize, SamplesInChunk - 1, FrameReader3).
  
calculate_sample_offsets(_FrameTable, #mp4_frames{chunk_offsets = []} = FrameReader) ->
  FrameReader;
  
calculate_sample_offsets(FrameTable, #mp4_frames{chunk_offsets = [ChunkOffset | ChunkOffsets]} = FrameReader) ->
  {SamplesInChunk, FrameReader1} = chunk_samples_count(FrameReader),
  
  % io:format("~p~n", [[ChunkOffset, SamplesInChunk]]),
  FrameReader2 = calculate_samples_in_chunk(FrameTable, ChunkOffset, SamplesInChunk, FrameReader1),
  calculate_sample_offsets(FrameTable, FrameReader2#mp4_frames{chunk_offsets = ChunkOffsets});

calculate_sample_offsets(#media_info{frames = FrameTable} = MediaInfo, Track) ->
  #mp4_track{
    chunk_offsets = ChunkOffsets, 
    chunk_table = ChunkTable, 
    keyframes = Keyframes, 
    sample_sizes = SampleSizes, 
    sample_durations = Durations,
    data_format = DataFormat,
    timescale = Timescale,
    composition_offsets = CompositionOffsets} = Track,
  
  % ?D({"Track", length(SampleSizes), length(Durations), length(CompositionOffsets)}),
  calculate_sample_offsets(FrameTable, 
    #mp4_frames{
      chunk_offsets = ChunkOffsets, 
      chunk_table = ChunkTable, 
      keyframes = Keyframes, 
      sample_sizes = SampleSizes, 
      durations = Durations, 
      data_format = DataFormat,
      timescale = Timescale,
      composition_offsets = CompositionOffsets}),
  MediaInfo.

  
-define(MP4ESDescrTag, 3).
-define(MP4DecConfigDescrTag, 4).
-define(MP4DecSpecificDescrtag, 5).

mp4_desc_length(<<0:1, Length:7, Rest:Length/binary, Rest2/binary>>) ->
  {Rest, Rest2};

mp4_desc_length(<<1:1, Length1:7, 0:1, Length:7, Rest/binary>>) ->
  TagLength = Length1 * 128 + Length,
  <<Rest1:TagLength/binary, Rest2/binary>> = Rest,
  {Rest1, Rest2};

mp4_desc_length(<<1:1, Length2:7, 1:1, Length1:7, 0:1, Length:7, Rest/binary>>)  ->
  TagLength = (Length2 bsl 14 + Length1 bsl 7 + Length),
  <<Rest1:TagLength/binary, Rest2/binary>> = Rest,
  {Rest1, Rest2};

mp4_desc_length(<<1:1, Length3:7, 1:1, Length2:7, 1:1, Length1:7, 0:1, Length:7, Rest/binary>>)  ->
  TagLength = (Length3 bsl 21 + Length2 bsl 14 + Length1 bsl 7 + Length),
  ?D({"MP4 desc length", TagLength}),
  <<Rest1:TagLength/binary, Rest2/binary>> = Rest,
  {Rest1, Rest2}.

%% FIXME: Code here must be relocated in some more generic place and way. 
%% Here goes not some esds tag, but IOD (Initial Object Description)
%% Look how to parse it at vlc/modules/demux/ts.c:2400
%%

esds_tag(<<3, Rest/binary>>) ->
  {DecoderConfigTag, _Other1} = mp4_desc_length(Rest),
  <<_HardcodedOffset:3/binary, 4, Rest1/binary>> = DecoderConfigTag,
  {SpecificInfoTag, _Other2} = mp4_desc_length(Rest1),
  <<_HardcodedOffset1:13/binary, ?MP4DecSpecificDescrtag, ConfigData/binary>> = SpecificInfoTag,
  {Config, _Other3} = mp4_desc_length(ConfigData),
  % ?D({"MP4DecSpecificDescrtag", Length, Config}),
  <<Config/binary>>;

esds_tag(<<_HardcodedOffset:20/binary, ?MP4DecSpecificDescrtag, Length, Config:Length/binary, _Rest/binary>>) ->
  % ?D({"MP4DecSpecificDescrtag", Length, Config}),
  <<Config/binary>>;
  
esds_tag(_) ->
  undefined.
  
 
