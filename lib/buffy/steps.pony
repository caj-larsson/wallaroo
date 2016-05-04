use "collections"
use "buffy/messages"
use "buffy/metrics"
use "time"

interface MetricsSender
  be add_metrics_collector(mc: MetricsCollector tag) => None

interface Identifiable
  be add_id(id: I32) => None

interface BasicStep is (MetricsSender & Identifiable)

interface ComputeStep[In: OSCEncodable val] is BasicStep
  be apply(input: Message[In] val)

interface ThroughStep[In: OSCEncodable val,
                      Out: OSCEncodable val] is ComputeStep[In]
  be add_output(to: ComputeStep[Out] tag)

actor Step[In: OSCEncodable val, Out: OSCEncodable val] is ThroughStep[In, Out]
  var _step_id: (I32 | None) = None
  let _f: Computation[In, Out]
  var _metrics_collector: (MetricsCollector tag | None) = None
  var _output: (ComputeStep[Out] tag | None) = None

  new create(f: Computation[In, Out] iso) =>
    _f = consume f

  be add_id(id: I32) =>
    _step_id = id

  be add_metrics_collector(m_coll: MetricsCollector tag) =>
    _metrics_collector = m_coll

  be add_output(to: ComputeStep[Out] tag) =>
    _output = to

  be apply(input: Message[In] val) =>
    match _output
    | let c: ComputeStep[Out] tag =>
      let start_time = Time.millis()
      c(_f(input))
      let end_time = Time.millis()
      _report_metrics(start_time, end_time)
    end

  fun _report_metrics(start_time: U64, end_time: U64) =>
    match _metrics_collector
    | let m: MetricsCollector tag =>
      match _step_id
      | let id: I32 =>
        m.report_step_metrics(id, start_time, end_time)
      end
    end

actor Sink[In: OSCEncodable val] is ComputeStep[In]
  var _step_id: (I32 | None) = None
  var _metrics_collector: (MetricsCollector tag | None) = None
  let _f: FinalComputation[In]

  new create(f: FinalComputation[In] iso) =>
    _f = consume f

  be apply(input: Message[In] val) =>
    _f(input)

  be add_id(id: I32) =>
    _step_id = id

  be add_metrics_collector(m_coll: MetricsCollector tag) =>
    _metrics_collector = m_coll


actor Partition[In: OSCEncodable val, Out: OSCEncodable val] is ThroughStep[In, Out]
  let _computation_type: String
  let _step_builder: StepBuilder val
  let _partition_function: PartitionFunction[In] val
  let _partitions: Map[I32, Any tag] = Map[I32, Any tag]
  var _output: (ComputeStep[Out] tag | None) = None

  new create(c_type: String val, pf: PartitionFunction[In] val,
    sb: StepBuilder val) =>
    _computation_type = c_type
    _partition_function = pf
    _step_builder = sb

  be apply(input: Message[In] val) =>
    let partition_id = _partition_function(input.data)
    if _partitions.contains(partition_id) then
      try
        match _partitions(partition_id)
        | let c: ComputeStep[In] tag => c(input)
        else
          @printf[String]("Partition not a ComputeStep!".cstring())
        end
      end
    else
      try
        let comp = _step_builder(_computation_type)
        _partitions(partition_id) = comp
        match comp
        | let t: ThroughStep[In, Out] tag =>
          match _output
          | let o: ComputeStep[Out] tag => t.add_output(o)
          end
          t(input)
        end
      else
        @printf[String]("Computation type is invalid!".cstring())
      end
    end

  be add_output(to: ComputeStep[Out] tag) =>
    _output = to
    for key in _partitions.keys() do
      try
        match _partitions(key)
        | let t: ThroughStep[In, Out] tag => t.add_output(to)
        else
          @printf[String]("Partition not a ThroughStep!".cstring())
        end
      else
          @printf[String]("Couldn't find partition when trying to add output!".cstring())
      end
    end
