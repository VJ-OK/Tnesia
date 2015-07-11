Tnesia
======

Tnesia is a time-series data storage based on Mnesia. You can run time-based queries on a large amount of data, without scanning the whole set of data, in a key-value manner.

Goal and Theory
-----
The goal is to reduce disk seeks in order to find a time range of data values in a timeline, ascending or descending, and from or to any arbitrary points of time.
There are few terms that can help you to understand how Tnesia stores and retrieves data, among them **Timeline**, **Timepoint** and **Timestep** are the main ones.


```
    +---------------------------+        
    |                           |        
    |     + timepoint # 01      |        
    |                           |        
    |                                          - timeline:
    |     + timepoint # 02   timestep # 1        an identifier to a
    |                                            series of chronological
    |     + timepoint # 03      |                timepoints
    |     + timepoint # 04      |        
    |                           |        
    +---------------------------+              - timepoint:
    |                           |                a pointer to a given
    |     + timepoint # 05      |                data value
    |     + timepoint # 06      |        
                                         
timeline  + timepoint # 07   timestep # 2      - timestep:
                                                 a partition on a
    |     + timepoint # 08      |                timeline that spilited
    |     + timepoint # 09      |                timepoints
    |                           |        
    +---------------------------+        
    |                           |        
    |     + timepoint # 10      |        
    |                           |        
    |     + timepoint # 11               
    |     + timepoint # 12   timestep # 3
    |                                    
    |                           |        
    |     + timepoint # 13      |        
    |                           |        
    +---------------------------+        
    |                           |        
    v                           v        
```

**Quick Facts**:

* Each timestep can contain arbitrary number of timepoints.
* All the orders are based on microsecond UNIX timestamp.
* Timepoints are just a pointer to its data value which stores somewhere else.
* Timepoints, as index, are stored on RAM to faster lookup.
* Data values are stored on Disk to have more room for storage.
* All seeks are **key-value**.
* Timestep precision is configurable depends on the timepoints frequency.

API
-----

**Write**

Writes a record on a timeline.

```erlang
tnesia_api:write(Timeline, Record) -> {Timeline, Timepoint}
```

**Read**

Reads a record from a timeline by its timepoint.

```erlang
tnesia_api:read(Timeline, Timepoint) -> Record
```

**Remove**

Removes a record from a timeline by its timepoint.

```erlang
tnesia_api:remove(Timeline, Timepoint) -> ok
```

**Query fetch**

Queries a timeline to return records without any filttering or mapping.

```erlang
tnesia_api:query_fetch(Query) -> [Record]
```

**Query filtermap**

Queries a timeline to return records with filltering and mapping.

```erlang
tnesia_api:query_filtermap(Query, FiltermapFun) -> [Record]
```

**Query foreach**

Queries a timeline and traverse on the records.

```erlang
tnesia_api:query_foreach(Query, ForeachFun) -> ok
```

**Query raw**

Queries a timeline deciding on the return and traversal method.

```erlang
tnesia_api:query_raw(Query, Return, Fun) -> [Record] | ok
```

Types
----

```erlang
Timeline :: any()
Record :: [{any(), any()}]
Timepoint :: integer()
Query :: [{timeline, Timeline},
          {since, Since},
          {till, Till},
          {order, Order},
          {limit, Limit}]
Since = Till :: integer()
Order :: asc | des
Limit :: integer() | unlimited
FiltermapFun :: fun((Record, RecordIndex, Limit) -> {true, Record} | false)
ForeachFun :: fun((RecordIndex, Record, Limit) -> true | any())
Fun :: FiltermapFun | ForeachFun
Return :: true | false
```

Contribute
----

Comments, contributions and patches are greatly appreciated.