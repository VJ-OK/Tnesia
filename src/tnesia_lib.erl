-module(tnesia_lib).

-export([
	 create_table/1,
         delete_table/0,
         recreate_table/1
	]).

-export([
	 table_info/0,
         table_cleanup/4,
         remove_record/2,
         remove_record/1,
	 seed_sample_data/2
	]).

-export([
	 write/1,
         read_timepoint/2,
         read_count/1,
         read_count_call/2,
         read_count_cast/2,
         read_since/1,
         read_since_call/2,
         read_since_cast/2,
         read_since_till/1,
         read_since_till_call/2,
         read_since_till_cast/2,
         read_range_days_call/4,
         read_range_days_cast/4,
	 remove_timepoint/2,
	 init_read_since_till/2
	]).

-export([
	 get_timestamp/1,
	 get_micro_timestamp/1,
	 get_micro_timestamp/2,
	 get_micro_timestep/1
	]).

-export([
	 default_timeline/0,
	 default_since/0,
	 default_till/0,
	 default_order/0,
	 default_limit/0
	]).

-define(TIME_COUNT_LIMIT_SEC, 3600 * 24 * 30).
-define(ITEM_COUNT_LIMIT_REC, 50).
-define(TIME_STEP_PERCISION_SEC, 60 * 60 * 24).

-define(DEFAULT_TIMELINE, "default-timeline").
-define(DEFAULT_ORDER, des).
-define(DEFAULT_LIMIT, 50).
-define(DEFAULT_SINCE, 1000000 * 3600 * 24 * 30).

-include("tnesia.hrl").

%%====================================================================
%% Table Management API
%%====================================================================

%%--------------------------------------------------------------------
%% create_table
%%--------------------------------------------------------------------
create_table(Fragments) ->

    mnesia:create_table(tnesia_base, 
			[
			 {disc_only_copies, [node()]},
			 {attributes, record_info(fields, tnesia_base)},
			 {type, set},
			 {frag_properties, 
			  [
			   {node_pool, [node()]},
			   {n_fragments, Fragments},
			   {n_disc_copies, 1}
			  ]}
			]),
    
    mnesia:create_table(tnesia_bag, 
			[
			 {disc_copies, [node()]},
			 {attributes, record_info(fields, tnesia_bag)},
			 {type, bag},
			 {frag_properties, 
			  [
			   {node_pool, [node()]},
			   {n_fragments, Fragments},
			   {n_disc_copies, 1}
			  ]}
			]),
    
    ok.

%%--------------------------------------------------------------------
%% delete_table
%%--------------------------------------------------------------------
delete_table() ->

    [mnesia:delete_table(Table) 
     || Table <- [tnesia_base, tnesia_bag]],

    ok.

%%--------------------------------------------------------------------
%% recreate_table
%%--------------------------------------------------------------------
recreate_table(Fragments) ->
    ok = delete_table(),
    ok = create_table(Fragments),
    ok.

%%--------------------------------------------------------------------
%% seed_sample_data
%%--------------------------------------------------------------------
seed_sample_data(Counter, Round) when Counter > 0 ->
    CounterBin = integer_to_binary(Counter),
    lists:foreach(
      fun(R) ->
	      RBin = integer_to_binary(R),
	      write(#tnesia_input{
		       timeline = <<"id-", CounterBin/binary>>, 
		       timepoint = now(), 
		       record = #tnesia_sample{
				   foo = <<RBin/binary, "-foo-", 
					   CounterBin/binary>>,
				   bar = <<RBin/binary, "-bar-", 
					   CounterBin/binary>>,
				   bat = <<RBin/binary, "-bat-", 
					   CounterBin/binary>>
				  }
		      })
      end,
      lists:seq(1, Round)
     ),
    seed_sample_data(Counter - 1, Round);
seed_sample_data(_, _) -> ok.

%%--------------------------------------------------------------------
%% table_info
%%--------------------------------------------------------------------
table_info() ->
    BaseSize = query_on_frags(
		 async_dirty,
		 fun() -> mnesia:table_info(tnesia_base, size) end
		),

    BagSize = query_on_frags(
		async_dirty,
		fun() -> mnesia:table_info(tnesia_bag, size) end
	       ),

    [{tnesia_base, BaseSize}, {tnesia_bag, BagSize}].

%%--------------------------------------------------------------------
%% table_cleanup
%%--------------------------------------------------------------------
table_cleanup(BagKey, Since, Till, Fun) ->
    read_range_days_cast(
      BagKey,
      Since,
      Till,
      fun(BaseRecord, BagRecord, _Limit) ->
	      case apply(Fun, [BaseRecord]) of
		  true -> 
		      remove_record(BagRecord, BaseRecord),
		      true;
		  _ -> 
		      false
	      end
      end
     ),
    ok.

%%--------------------------------------------------------------------
%% remove_record
%%--------------------------------------------------------------------
remove_record(BagRecord) -> 
    [BaseRecord] = 
	query_on_frags(
	  async_dirty,
	  fun() ->
		  mnesia:read({tnesia_base, 
			       BagRecord#tnesia_bag.base_key})
	  end
	 ),
    remove_record(BagRecord, BaseRecord).

%%--------------------------------------------------------------------
%% remove_record
%%--------------------------------------------------------------------
remove_record(BagRecord, BaseRecord) ->
    query_on_frags(
      transaction,
      fun() ->
	      mnesia:delete_object(BagRecord),
	      mnesia:delete_object(BaseRecord)
      end
     ).

%%====================================================================
%% Query API
%%====================================================================

%%--------------------------------------------------------------------
%% write
%%--------------------------------------------------------------------
write(#tnesia_input{
	 timeline = Timeline, 
	 timepoint = TupleTimepoint,
	 record = Record
	} = _Input) ->

    Timepoint = get_micro_timestamp(TupleTimepoint),

    BaseRecord = #tnesia_base{
		    base_key = {Timeline, Timepoint},
		    base_val = Record
		   },

    Timestep = get_micro_timestep(Timepoint),

    BagRecord = #tnesia_bag{
		   bag_key = {Timeline, Timestep},
		   base_key = BaseRecord#tnesia_base.base_key
		  },

    WriteFun = fun() ->
		       mnesia:write(BaseRecord),
		       mnesia:write(BagRecord)
	       end,

    mnesia:activity(transaction, WriteFun, [], mnesia_frag),

    Timepoint.

%%--------------------------------------------------------------------
%% read_timepoint
%%--------------------------------------------------------------------
read_timepoint(Timeline, Timepoint) ->
    query_on_frags(
      async_dirty, 
      fun() ->
	      mnesia:read({tnesia_base, {Timeline, Timepoint}})
      end
     ).

%%--------------------------------------------------------------------
%% read_count
%%--------------------------------------------------------------------
read_count(Query) ->
    read_count_call(Query, fun(_Val, _Limit) -> true end).

%%--------------------------------------------------------------------
%% read_count_call
%%--------------------------------------------------------------------
read_count_call(Query, Fun) ->
    Now = now(),
    TimepointFrom = get_micro_timestamp_count_limit(Now),
    TimepointTo = get_micro_timestamp(Now),
    read_since_till_call(
      Query#tnesia_query{
	from = TimepointFrom, 
	to = TimepointTo
       },
      Fun
     ).

%%--------------------------------------------------------------------
%% read_count_cast
%%--------------------------------------------------------------------
read_count_cast(Query, Fun) ->
    Now = now(),
    TimepointFrom = get_micro_timestamp_count_limit(Now),
    TimepointTo = get_micro_timestamp(Now),
    read_since_till_cast(
      Query#tnesia_query{
	from = TimepointFrom, 
	to = TimepointTo
       },
      Fun
     ).

%%--------------------------------------------------------------------
%% read_since
%%--------------------------------------------------------------------
read_since(Query) ->
    read_since_call(Query, fun(_Val, _Limit) -> true end).

%%--------------------------------------------------------------------
%% read_since_call
%%--------------------------------------------------------------------
read_since_call(Query, Fun) ->
    TimepointTo = get_micro_timestamp(now()),
    read_since_till_call(Query#tnesia_query{to = TimepointTo}, Fun).

%%--------------------------------------------------------------------
%% read_since_cast
%%--------------------------------------------------------------------
read_since_cast(Query, Fun) ->
    TimepointTo = get_micro_timestamp(now()),
    read_since_till_cast(Query#tnesia_query{to = TimepointTo}, Fun).

%%--------------------------------------------------------------------
%% read_since_till
%%--------------------------------------------------------------------
read_since_till(Query) ->
    read_since_till_call(Query, fun(_Val, _Limit) -> true end).

%%--------------------------------------------------------------------
%% read_since_till_call
%%--------------------------------------------------------------------
read_since_till_call(Query, Fun) ->
    init_read_since_till(Query#tnesia_query{return = true}, Fun).

%%--------------------------------------------------------------------
%% read_since_till_cast
%%--------------------------------------------------------------------
read_since_till_cast(Query, Fun) ->
    init_read_since_till(Query#tnesia_query{return = false}, Fun).

%%--------------------------------------------------------------------
%% read_range_days_call
%%--------------------------------------------------------------------
read_range_days_call(Bag, Since, Till, Fun) ->
    init_read_range_days(Bag, Since, Till, true, Fun).

%%--------------------------------------------------------------------
%% read_range_days_cast
%%--------------------------------------------------------------------
read_range_days_cast(Bag, Since, Till, Fun) ->
    init_read_range_days(Bag, Since, Till, false, Fun).

%%--------------------------------------------------------------------
%% remove_timepoint
%%--------------------------------------------------------------------
remove_timepoint(Timeline, Timepoint) ->
    Timestep = get_micro_timestep(Timepoint),
    BaseKey = {Timeline, Timepoint},
    BagKey = {Timeline, Timestep},

    query_on_frags(
      transaction,
      fun() ->
	      mnesia:delete({tnesia_base, BaseKey}),
	      mnesia:delete_object({tnesia_bag, BagKey, BaseKey})
      end
     ).

%%====================================================================
%% Tools
%%====================================================================

%%--------------------------------------------------------------------
%% init_read_since_till
%%--------------------------------------------------------------------
init_read_since_till(#tnesia_query{
			from = TimepointFrom,
			to = TimepointTo,
			order = Order
		       } = Query, 
		     Fun
		    ) ->

    TimestepFrom = get_micro_timestep(TimepointFrom),
    TimestepTo = get_micro_timestep(TimepointTo),
    Timestep =
	case Order of
	    asc -> TimestepFrom;
	    des -> TimestepTo
	end,

    State = [],
    run_tnesia_query(
      Query,
      TimepointFrom,
      TimepointTo,
      Timestep,
      TimestepFrom, 
      TimestepTo, 
      Fun, 
      State
     ).

%%--------------------------------------------------------------------
%% init_read_range_days
%%--------------------------------------------------------------------
init_read_range_days(Bag, Since, Till, Return, Fun)
  when 
      is_integer(Since),
      is_integer(Till),
      Since > Till
      ->
    Now = now(),
    OneDayMicro = (1000 * 1000) * (60 * 60) * 24,
    NowMicro = get_micro_timestamp(Now),
    SinceMicro = NowMicro - (OneDayMicro * Since),
    TillMicro = NowMicro - (OneDayMicro * Till),
    read_since_till_call(
      #tnesia_query{
         bag = Bag, 
         from = SinceMicro, 
         to = TillMicro,
         return = Return,
         limit = unlimited
	},
      Fun
     ).

%%--------------------------------------------------------------------
%% run_tnesia_query
%%--------------------------------------------------------------------
run_tnesia_query(#tnesia_query{
		    bag = Bag,
		    limit = Limit,
		    order = Order,
		    return = Return
		   } = Query,
		 TimepointFrom,
		 TimepointTo,
		 Timestep, 
		 TimestepFrom, 
		 TimestepTo, 
		 Fun,
		 State
		) when 
      TimestepFrom =< TimestepTo, Limit > 0;
      TimestepFrom =< TimestepTo, Limit =:= unlimited 
      ->

    BagRecords = query_on_frags(
		   async_dirty,
		   fun() ->
			   mnesia:read({tnesia_bag, {Bag, Timestep}})
		   end
		  ),

    SortedBagRecords =
	case Order of
	    asc -> BagRecords;
	    des -> lists:reverse(BagRecords)
	end,

    %% @TODO: check it!
    {NewLimit, NewState} =
	case Return of
	    false -> cast_on_bag(SortedBagRecords, Query, Fun, State);
	    true -> call_on_bag(SortedBagRecords, Query, Fun, State)
	end,

    {NewTimepointFrom, NewTimepointTo} =
	case Order of
	    asc -> 
		{TimepointFrom + get_micro_timestep_precision(), TimepointTo};
	    des -> 
		{TimepointFrom, TimepointTo - get_micro_timestep_precision()}
	end,

    NewTimestepFrom = get_micro_timestep(NewTimepointFrom),
    NewTimestepTo = get_micro_timestep(NewTimepointTo),

    NewTimestep =
	case Order of
	    asc -> NewTimestepFrom;
	    des -> NewTimestepTo
	end,

    run_tnesia_query(
      Query#tnesia_query{limit = NewLimit},
      NewTimepointFrom,
      NewTimepointTo,
      NewTimestep,
      NewTimestepFrom,
      NewTimestepTo,
      Fun,
      NewState
     );
run_tnesia_query(_, _, _, _, _, _, _, State) -> State.

%%--------------------------------------------------------------------
%% cast_on_bag
%%--------------------------------------------------------------------
cast_on_bag(
  [BagRecord|Tail] = _BagRecords, 
  #tnesia_query{
     limit = Limit,
     from = TimepointFrom,
     to = TimepointTo
    } = Query, 
  Fun,
  State
 ) when 
      Limit > 0; 
      Limit =:= unlimited 
      ->

    {Bag, BaseKeyTime} = BagRecord#tnesia_bag.base_key,
    Times = {BaseKeyTime, TimepointFrom, TimepointTo},
    case check_timestep_fault(Times) of
	true ->
	    [BaseRecord] = 
		query_on_frags(
		  async_dirty,
		  fun() ->
			  mnesia:read({
					tnesia_base,
					{Bag, BaseKeyTime}
				      })
		  end
		 ),
	    
	    NewLimit =
		case apply(Fun, [BaseRecord, BagRecord, Limit]) of
		    true -> 
			case Limit of 
			    unlimited -> unlimited;
			    _ -> Limit - 1
			end
			    ;
		    _ -> Limit
		end,

	    cast_on_bag(Tail, Query#tnesia_query{limit = NewLimit}, Fun, State);
	_ -> cast_on_bag(Tail, Query#tnesia_query{limit = Limit}, Fun, State)
    end;
cast_on_bag(
  _UnwantedBagRecords, 
  #tnesia_query{limit = Limit}, 
  _Fun, 
  State
 ) -> {Limit, State};
cast_on_bag(
  [], 
  #tnesia_query{limit = Limit}, 
  _Fun, 
  State
 ) -> {Limit, State}.

%%--------------------------------------------------------------------
%% call_on_bag
%%--------------------------------------------------------------------
call_on_bag(
  [BagRecord|Tail] = _BagRecords, 
  #tnesia_query{
     limit = Limit,
     from = TimepointFrom,
     to = TimepointTo
    } = Query, 
  Fun,
  State
 ) when 
      Limit > 0; 
      Limit =:= unlimited 
      ->

    {Bag, BaseKeyTime} = BagRecord#tnesia_bag.base_key,
    Times = {BaseKeyTime, TimepointFrom, TimepointTo},
    case check_timestep_fault(Times) of
	true ->
	    [BaseRecord] = query_on_frags(
			     async_dirty,
			     fun() ->
				     mnesia:read({
						   tnesia_base,
						   {Bag, BaseKeyTime}
						 })
			     end
			    ),

	    {NewLimit, NewState} =
		case apply(Fun, [BaseRecord, BagRecord, Limit]) of
		    {true, Record} ->
			case Limit of 
			    unlimited -> {unlimited, lists:append(State, [Record])};
			    _ -> {Limit - 1, lists:append(State, [Record])}
			end
			    ;
		    _ -> {Limit, State}
		end,

	    call_on_bag(Tail, Query#tnesia_query{limit = NewLimit}, Fun, NewState);
	_ -> call_on_bag(Tail, Query#tnesia_query{limit = Limit}, Fun, State)
    end;
call_on_bag(
  _UnwantedBagRecords, 
  #tnesia_query{limit = Limit}, 
  _Fun, 
  State
 ) -> {Limit, State};
call_on_bag(
  [],
  #tnesia_query{limit = Limit},
  _Fun,
  State
 ) -> {Limit, State}.

%%====================================================================
%% Utilities
%%====================================================================

%%--------------------------------------------------------------------
%% query_on_frags
%%--------------------------------------------------------------------
query_on_frags(Type, Fun) ->
    mnesia:activity(Type, Fun, [], mnesia_frag).

%%--------------------------------------------------------------------
%% check_timestep_fault
%%--------------------------------------------------------------------
check_timestep_fault({BaseKeyTime, TimeStampFrom, TimeStampTo}) ->
    (BaseKeyTime >= TimeStampFrom) andalso (BaseKeyTime =< TimeStampTo).
%%--------------------------------------------------------------------
%% get_timestamp
%%--------------------------------------------------------------------
get_timestamp(TupleTime) ->
    {Mega, Sec, _Micro} = TupleTime,
    SecTimeStamp = (Mega * 1000000 + Sec),
    SecTimeStamp.
%%--------------------------------------------------------------------
%% get_micro_timestamp
%%--------------------------------------------------------------------
get_micro_timestamp(TupleTime) ->
    {Mega, Sec, Micro} = TupleTime,
    SecTimeStamp = (Mega * 1000000 + Sec),
    MicroTimeStamp = (SecTimeStamp * 1000000) + Micro,
    MicroTimeStamp.

get_micro_timestamp(Date, Time) ->
    Seconds = calendar:datetime_to_gregorian_seconds({Date, Time}) - 62167219200,
    TupleTime = {Seconds div 1000000, Seconds rem 1000000, 0},
    get_micro_timestamp(TupleTime).

%%--------------------------------------------------------------------
%% get_micro_timestep
%%--------------------------------------------------------------------
get_micro_timestep(MicroTimeStamp) ->
    Rem = MicroTimeStamp rem get_micro_timestep_precision(),
    MicroTimeStamp - Rem.

%%--------------------------------------------------------------------
%% get_micro_timestep_precision
%%--------------------------------------------------------------------
get_micro_timestep_precision() ->
    ?TIME_STEP_PERCISION_SEC * 1000000.

%%--------------------------------------------------------------------
%% get_micro_timestamp_count_limit
%%--------------------------------------------------------------------
get_micro_timestamp_count_limit(TupleTime) ->
    get_micro_timestamp(TupleTime) - (?TIME_COUNT_LIMIT_SEC * 1000000).

%%====================================================================
%% Defaults
%%====================================================================

%%--------------------------------------------------------------------
%% default_timeline
%%--------------------------------------------------------------------
default_timeline() ->
    ?DEFAULT_TIMELINE.

%%--------------------------------------------------------------------
%% default_since
%%--------------------------------------------------------------------
default_since() ->
    default_till() - ?DEFAULT_SINCE.
%%--------------------------------------------------------------------
%% default_till
%%--------------------------------------------------------------------
default_till() ->
    get_micro_timestamp(now()).

%%--------------------------------------------------------------------
%% default_order
%%--------------------------------------------------------------------
default_order() ->
    ?DEFAULT_ORDER.

%%--------------------------------------------------------------------
%% default_limit
%%--------------------------------------------------------------------
default_limit() ->
    ?DEFAULT_LIMIT.
