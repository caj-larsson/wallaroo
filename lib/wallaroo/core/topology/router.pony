/*

Copyright 2017 The Wallaroo Authors.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 implied. See the License for the specific language governing
 permissions and limitations under the License.

*/

use "collections"
use "crypto"
use "net"
use "wallaroo/core/boundary"
use "wallaroo/core/common"
use "wallaroo/core/source"
use "wallaroo/ent/barrier"
use "wallaroo/ent/data_receiver"
use "wallaroo/ent/rebalancing"
use "wallaroo/ent/router_registry"
use "wallaroo/ent/checkpoint"
use "wallaroo/core/invariant"
use "wallaroo/core/messages"
use "wallaroo/core/routing"
use "wallaroo/core/sink"
use "wallaroo/core/state"
use "wallaroo_labs/collection_helpers"
use "wallaroo_labs/equality"
use "wallaroo_labs/mort"

trait val Router is (Hashable & Equatable[Router])
  fun route[D: Any val](metric_name: String, pipeline_time_spent: U64, data: D,
    producer_id: RoutingId, producer: Producer ref, i_msg_uid: MsgId,
    frac_ids: FractionalMessageId, latest_ts: U64, metrics_id: U16,
    worker_ingress_ts: U64): (Bool, U64)
  fun routes(): Map[RoutingId, Consumer] val
  fun routes_not_in(router: Router): Map[RoutingId, Consumer] val

primitive EmptyRouter is Router
  fun route[D: Any val](metric_name: String, pipeline_time_spent: U64, data: D,
    producer_id: RoutingId, producer: Producer ref, i_msg_uid: MsgId,
    frac_ids: FractionalMessageId, latest_ts: U64, metrics_id: U16,
    worker_ingress_ts: U64): (Bool, U64)
  =>
    (true, latest_ts)

  fun routes(): Map[RoutingId, Consumer] val =>
    recover Map[RoutingId, Consumer] end

  fun routes_not_in(router: Router): Map[RoutingId, Consumer] val =>
    recover Map[RoutingId, Consumer] end

  fun eq(that: box->Router): Bool =>
    that is EmptyRouter

  fun hash(): USize =>
    0

class val DirectRouter is Router
  let _target_id: RoutingId
  let _target: Consumer

  new val create(t_id: RoutingId, target: Consumer) =>
    _target_id = t_id
    _target = target

  fun route[D: Any val](metric_name: String, pipeline_time_spent: U64, data: D,
    producer_id: RoutingId, producer: Producer ref, i_msg_uid: MsgId,
    frac_ids: FractionalMessageId, latest_ts: U64, metrics_id: U16,
    worker_ingress_ts: U64): (Bool, U64)
  =>
    ifdef "trace" then
      @printf[I32]("Rcvd msg at DirectRouter\n".cstring())
    end

    let might_be_route = producer.route_to(_target)
    match might_be_route
    | let r: Route =>
      ifdef "trace" then
        @printf[I32]("DirectRouter found Route\n".cstring())
      end
      r.run[D](metric_name, pipeline_time_spent, data,
        // hand down producer so we can call _next_sequence_id()
        producer_id, producer,
        // incoming envelope
        i_msg_uid, frac_ids,
        latest_ts, metrics_id, worker_ingress_ts)
      (false, latest_ts)
    else
      // TODO: What do we do if we get None?
      (true, latest_ts)
    end

  fun routes(): Map[RoutingId, Consumer] val =>
    let m = recover iso Map[RoutingId, Consumer] end
    m(_target_id) = _target
    consume m

  fun routes_not_in(router: Router): Map[RoutingId, Consumer] val =>
    let m = recover iso Map[RoutingId, Consumer] end
    for (id, c) in router.routes().pairs() do
      if _target_id == id then
        return consume m
      end
    end
    m(_target_id) = _target
    consume m

  fun eq(that: box->Router): Bool =>
    match that
    | let dr: DirectRouter =>
      (_target_id == dr._target_id) and (_target is dr._target)
    else
      false
    end

  fun hash(): USize =>
    _target_id.hash() xor (digestof _target).hash()

class val MultiRouter is Router
  let _routers: Array[Router] val

  new val create(routers: Array[Router] val) =>
    _routers = routers

  fun route[D: Any val](metric_name: String, pipeline_time_spent: U64, data: D,
    producer_id: RoutingId, producer: Producer ref, i_msg_uid: MsgId,
    frac_ids: FractionalMessageId, latest_ts: U64, metrics_id: U16,
    worker_ingress_ts: U64): (Bool, U64)
  =>
    ifdef "trace" then
      @printf[I32]("Rcvd msg at MultiRouter\n".cstring())
    end
    var is_finished = true
    for (next_o_frac_id, router) in _routers.pairs() do
      let o_frac_ids =
        match frac_ids
        | None =>
          recover val Array[U32].init(next_o_frac_id.u32(), 1) end
        | let f_ids: Array[U32 val] val =>
          recover val
            let z = Array[U32](f_ids.size() + 1)
            for f_id in f_ids.values() do
              z.push(f_id)
            end
            z.push(next_o_frac_id.u32())
            z
          end
        end
      (let is_f, _) = router.route[D](metric_name, pipeline_time_spent, data,
        // hand down producer so we can call _next_sequence_id()
        producer_id, producer,
        // incoming envelope
        i_msg_uid, o_frac_ids,
        latest_ts, metrics_id, worker_ingress_ts)
      // If any of the messages sent downstream are not finished, then
      // we report that this message is not finished yet.
      if not is_f then is_finished = false end
    end
    (is_finished, latest_ts)

  fun routes(): Map[RoutingId, Consumer] val =>
    let m = recover iso Map[RoutingId, Consumer] end
    for router in _routers.values() do
      for (id, r) in router.routes().pairs() do
        m(id) = r
      end
    end
    consume m

  fun routes_not_in(router: Router): Map[RoutingId, Consumer] val =>
    let rs = recover iso Map[RoutingId, Consumer] end
    let those_routes = router.routes()
    for (id, r) in routes().pairs() do
      if not those_routes.contains(id) then
        rs(id) = r
      end
    end
    consume rs

  fun eq(that: box->Router): Bool =>
    match that
    | let mr: MultiRouter =>
      try
        let theirs = mr._routers
        if _routers.size() != theirs.size() then return false end
        var is_equal = true
        for i in Range(0, _routers.size()) do
          if _routers(i)? != theirs(i)? then is_equal = false end
        end
        is_equal
      else
        false
      end
    else
      false
    end

  fun hash(): USize =>
    try
      var h = _routers(0)?.hash()
      if _routers.size() > 1 then
        for i in Range(1, _routers.size()) do
          h = h xor _routers(i)?.hash()
        end
      end
      h
    else
      0
    end

class val ProxyRouter is Router
  let _worker_name: String
  let _target: OutgoingBoundary
  let _target_proxy_address: ProxyAddress
  let _auth: AmbientAuth

  new val create(worker_name: String, target: OutgoingBoundary,
    target_proxy_address: ProxyAddress, auth: AmbientAuth)
  =>
    _worker_name = worker_name
    _target = target
    _target_proxy_address = target_proxy_address
    _auth = auth

  fun route[D: Any val](metric_name: String, pipeline_time_spent: U64, data: D,
    producer_id: RoutingId, producer: Producer ref, i_msg_uid: MsgId,
    frac_ids: FractionalMessageId, latest_ts: U64, metrics_id: U16,
    worker_ingress_ts: U64): (Bool, U64)
  =>
    ifdef "trace" then
      @printf[I32]("Rcvd msg at ProxyRouter\n".cstring())
    end

    let might_be_route = producer.route_to(_target)
    match might_be_route
    | let r: Route =>
      ifdef "trace" then
        @printf[I32]("ProxyRouter found Route\n".cstring())
      end
      let delivery_msg = ForwardMsg[D](
        _target_proxy_address.routing_id,
        _worker_name, data, metric_name,
        _target_proxy_address,
        i_msg_uid, frac_ids)

      r.forward(delivery_msg, pipeline_time_spent, producer_id, producer,
        latest_ts, metrics_id, metric_name, worker_ingress_ts)

      (false, latest_ts)
    else
      Fail()
      (true, latest_ts)
    end

  fun copy_with_new_target_id(target_id: RoutingId): ProxyRouter =>
    ProxyRouter(_worker_name, _target,
      ProxyAddress(_target_proxy_address.worker, target_id), _auth)

  fun routes(): Map[RoutingId, Consumer] val =>
    let m = recover iso Map[RoutingId, Consumer] end
    m(_target_proxy_address.routing_id) = _target
    consume m

  fun routes_not_in(router: Router): Map[RoutingId, Consumer] val =>
    let m = recover iso Map[RoutingId, Consumer] end
    if router.routes().contains(_target_proxy_address.routing_id) then
      consume m
    else
      m(_target_proxy_address.routing_id) = _target
      consume m
    end

  fun update_proxy_address(pa: ProxyAddress): ProxyRouter =>
    ProxyRouter(_worker_name, _target, pa, _auth)

  fun val update_boundary(ob: box->Map[String, OutgoingBoundary]):
    ProxyRouter
  =>
    try
      let new_target = ob(_target_proxy_address.worker)?
      if new_target isnt _target then
        ProxyRouter(_worker_name, new_target, _target_proxy_address, _auth)
      else
        this
      end
    else
      Fail()
      this
    end

  fun proxy_address(): ProxyAddress =>
    _target_proxy_address

  fun target_boundary(): OutgoingBoundary =>
    _target

  fun eq(that: box->Router): Bool =>
    match that
    | let pr: ProxyRouter =>
      (_worker_name == pr._worker_name) and
        (_target is pr._target) and
        (_target_proxy_address == pr._target_proxy_address)
    else
      false
    end

  fun hash(): USize =>
    _target_proxy_address.hash()

trait val TargetIdRouter is Equatable[TargetIdRouter]
  fun route_with_target_ids[D: Any val](target_ids: Array[RoutingId] val,
    metric_name: String, pipeline_time_spent: U64, data: D,
    producer_id: RoutingId, producer: Producer ref, msg_uid: MsgId,
    frac_ids: FractionalMessageId, latest_ts: U64, metrics_id: U16,
    worker_ingress_ts: U64): (Bool, U64)

  fun val update_boundaries(obs: Map[String, OutgoingBoundary] box):
    TargetIdRouter

  fun val update_route_to_proxy(id: RoutingId, worker: String): TargetIdRouter

  fun val remove_proxy(id: RoutingId, worker: String,
    boundary: OutgoingBoundary): TargetIdRouter

  fun val update_route_to_consumer(id: RoutingId, step: Consumer): TargetIdRouter

  fun val add_consumer(id: RoutingId, consumer: Consumer): TargetIdRouter
  fun val remove_consumer(id: RoutingId, consumer: Consumer): TargetIdRouter

  fun val update_stateless_partition_router(id: RoutingId,
    pr: StatelessPartitionRouter): TargetIdRouter

  fun routes(): Map[RoutingId, Consumer] val

  fun routes_not_in(router: TargetIdRouter): Map[RoutingId, Consumer] val

  fun boundaries(): Map[String, OutgoingBoundary] val

  fun stateless_partition_ids(): Array[U128] val

  fun blueprint(): TargetIdRouterBlueprint

class val EmptyTargetIdRouter is TargetIdRouter
  fun route_with_target_ids[D: Any val](target_ids: Array[RoutingId] val,
    metric_name: String, pipeline_time_spent: U64, data: D,
    producer_id: RoutingId, producer: Producer ref, msg_uid: MsgId,
    frac_ids: FractionalMessageId, latest_ts: U64, metrics_id: U16,
    worker_ingress_ts: U64): (Bool, U64)
  =>
    @printf[I32]("route_with_target_ids() was called on an EmptyTargetIdRouter\n"
      .cstring())
    (true, latest_ts)

  fun val update_boundaries(obs: Map[String, OutgoingBoundary] box):
    TargetIdRouter
  =>
    this

  fun val update_route_to_proxy(id: RoutingId, worker: String): TargetIdRouter
  =>
    this

  fun val remove_proxy(id: RoutingId, worker: String, boundary: OutgoingBoundary):
    TargetIdRouter
  =>
    this

  fun val update_route_to_consumer(id: RoutingId, step: Consumer): TargetIdRouter
  =>
    this

  fun val add_consumer(id: RoutingId, consumer: Consumer): TargetIdRouter =>
    this

  fun val remove_consumer(id: RoutingId, consumer: Consumer): TargetIdRouter =>
    this

  fun val update_stateless_partition_router(id: RoutingId,
    pr: StatelessPartitionRouter): TargetIdRouter
  =>
    this

  fun routes(): Map[RoutingId, Consumer] val =>
    recover Map[RoutingId, Consumer] end

  fun routes_not_in(router: TargetIdRouter): Map[RoutingId, Consumer] val =>
    recover Map[RoutingId, Consumer] end

  fun eq(that: box->TargetIdRouter): Bool =>
    false

  fun boundaries(): Map[String, OutgoingBoundary] val =>
    recover Map[String, OutgoingBoundary] end

  fun stateless_partition_ids(): Array[U128] val =>
    recover Array[U128] end

  fun blueprint(): TargetIdRouterBlueprint =>
    EmptyTargetIdRouterBlueprint

class val StateStepRouter is TargetIdRouter
  let _worker_name: String
  let _consumers: Map[RoutingId, Consumer] val
  let _proxies: Map[RoutingId, ProxyAddress] val
  let _outgoing_boundaries: Map[String, OutgoingBoundary] val
  let _stateless_partitions: Map[RoutingId, StatelessPartitionRouter] val
  let _target_workers: Array[String] val

  new val create(worker_name: String,
    consumers: Map[RoutingId, Consumer] val,
    proxies: Map[RoutingId, ProxyAddress] val,
    outgoing_boundaries: Map[String, OutgoingBoundary] val,
    stateless_partitions: Map[U128, StatelessPartitionRouter] val,
    target_workers: Array[String] val)
  =>
    _worker_name = worker_name
    _consumers = consumers
    _proxies = proxies
    _outgoing_boundaries = outgoing_boundaries
    _stateless_partitions = stateless_partitions
    _target_workers = target_workers

  new val from_boundaries(w: String, obs: Map[String, OutgoingBoundary] val) =>
    _worker_name = w
    _consumers = recover Map[RoutingId, Consumer] end
    _proxies = recover Map[RoutingId, ProxyAddress] end
    _outgoing_boundaries = obs
    _stateless_partitions = recover Map[U128, StatelessPartitionRouter] end
    _target_workers = recover Array[String] end

  fun route_with_target_ids[D: Any val](target_ids: Array[RoutingId] val,
    metric_name: String, pipeline_time_spent: U64, data: D,
    producer_id: RoutingId, producer: Producer ref, msg_uid: MsgId,
    frac_ids: FractionalMessageId, latest_ts: U64, metrics_id: U16,
    worker_ingress_ts: U64): (Bool, U64)
  =>
    ifdef "trace" then
      @printf[I32]("Rcvd msg at StateStepRouter\n".cstring())
    end
    ifdef debug then
      Invariant(target_ids.size() > 0)
    end
    var is_finished = true
    if target_ids.size() == 1 then
      try
        (is_finished, _) = _route_with_target_id[D](target_ids(0)?,
          metric_name, pipeline_time_spent, data, producer_id, producer,
          msg_uid, frac_ids, latest_ts, metrics_id, worker_ingress_ts)
      else
        Fail()
      end
    else
      for (next_o_frac_id, next_target_id) in target_ids.pairs() do
        let o_frac_ids =
          match frac_ids
          | None =>
            recover val Array[U32].init(next_o_frac_id.u32(), 1) end
          | let f_ids: Array[U32 val] val =>
            recover val
              let z = Array[U32](f_ids.size() + 1)
              for f_id in f_ids.values() do
                z.push(f_id)
              end
              z.push(next_o_frac_id.u32())
              z
            end
          end

        (let is_f, _) = _route_with_target_id[D](next_target_id, metric_name,
          pipeline_time_spent, data, producer_id, producer, msg_uid,
          o_frac_ids, latest_ts, metrics_id, worker_ingress_ts)

        // If at least one downstream message is not finished, then this
        // message is not yet finished
        if not is_f then is_finished = false end
      end
    end
    (is_finished, latest_ts)

  fun _route_with_target_id[D: Any val](target_id: RoutingId,
    metric_name: String, pipeline_time_spent: U64, data: D,
    producer_id: RoutingId, producer: Producer ref, msg_uid: MsgId,
    frac_ids: FractionalMessageId, latest_ts: U64, metrics_id: U16,
    worker_ingress_ts: U64): (Bool, U64)
  =>
    if _consumers.contains(target_id) then
      try
        let target = _consumers(target_id)?

        let might_be_route = producer.route_to(target)
        match might_be_route
        | let r: Route =>
          ifdef "trace" then
            @printf[I32]("StateStepRouter found Route to Step\n".cstring())
          end
          r.run[D](metric_name, pipeline_time_spent, data,
            producer_id, producer, msg_uid, frac_ids,
            latest_ts, metrics_id, worker_ingress_ts)

          (false, latest_ts)
        else
          // No route for this target
          Fail()
          (true, latest_ts)
        end
      else
        Unreachable()
        (true, latest_ts)
      end
    else
      // This target_id step exists on another worker
      if _proxies.contains(target_id) then
        try
          let pa = _proxies(target_id)?
          try
            // Try as though we have a reference to the right boundary
            let boundary = _outgoing_boundaries(pa.worker)?
            let might_be_route = producer.route_to(boundary)
            match might_be_route
            | let r: Route =>
              ifdef "trace" then
                @printf[I32](("StateStepRouter found Route to " +
                  " OutgoingBoundary\n").cstring())
              end
              let delivery_msg = ForwardMsg[D](pa.routing_id,
                _worker_name, data, metric_name,
                pa, msg_uid, frac_ids)

              r.forward(delivery_msg, pipeline_time_spent, producer_id,
                producer, latest_ts, metrics_id,
                metric_name, worker_ingress_ts)
              (false, latest_ts)
            else
              // We don't have a route to this boundary
              ifdef debug then
                @printf[I32]("StateStepRouter had no Route\n".cstring())
              end
              Fail()
              (true, latest_ts)
            end
          else
            // We don't have a reference to the right outgoing boundary
            ifdef debug then
              @printf[I32](("StateStepRouter has no reference to " +
                " OutgoingBoundary\n").cstring())
            end
            Fail()
            (true, latest_ts)
          end
        else
          Fail()
          (true, latest_ts)
        end
      else
        try
          _stateless_partitions(target_id)?.route[D](metric_name,
            pipeline_time_spent, data, producer_id, producer, msg_uid,
            frac_ids, latest_ts, metrics_id, worker_ingress_ts)
        else
          // Apparently this target_id does not refer to a valid step id
          ifdef debug then
            @printf[I32](("StateStepRouter: target id does not refer to " +
              "valid step id\n").cstring())
          end
          Fail()
          (true, latest_ts)
        end
      end
    end

  fun val update_route_to_consumer(id: RoutingId, consumer: Consumer):
    TargetIdRouter
  =>
    let dr = recover iso Map[RoutingId, Consumer] end
    for (c_id, c) in _consumers.pairs() do
      dr(c_id) = c
    end
    dr(id) = consumer
    var new_router: TargetIdRouter = StateStepRouter(_worker_name, consume dr,
      _proxies, _outgoing_boundaries, _stateless_partitions, _target_workers)

    // If we have a proxy to this step, then we need to remove it now.
    if _proxies.contains(id) then
      try
        let pa = _proxies(id)?
        try
          new_router = new_router.remove_proxy(id, pa.worker,
            _outgoing_boundaries(pa.worker)?)
        else
          Fail()
        end
      else
        Unreachable()
      end
    end

    new_router

  fun val add_consumer(id: RoutingId, consumer: Consumer): TargetIdRouter =>
    match consumer
    | let ob: OutgoingBoundary =>
      var target = ""
      for (w, b) in _outgoing_boundaries.pairs() do
        if ob is b then
          target = w
        end
      end
      if target == "" then Fail() end
      update_route_to_proxy(id, target)
    else
      update_route_to_consumer(id, consumer)
    end

  fun val remove_consumer(id: RoutingId, consumer: Consumer): TargetIdRouter =>
    let dr = recover iso Map[RoutingId, Consumer] end
    for (c_id, c) in _consumers.pairs() do
      if c_id != id then
        dr(c_id) = c
      end
    end
    StateStepRouter(_worker_name, consume dr, _proxies, _outgoing_boundaries,
      _stateless_partitions, _target_workers)

  fun val update_route_to_proxy(id: RoutingId, worker: String): TargetIdRouter
  =>
    let ps = recover iso Map[RoutingId, ProxyAddress] end
    for (s_id, pa) in _proxies.pairs() do
      ps(s_id) = pa
    end
    ps(id) = ProxyAddress(worker, id)
    let tws =
      if not ArrayHelpers[String].contains[String](_target_workers, worker)
      then
        let a = recover iso Array[String] end
        for w in _target_workers.values() do
          a.push(w)
        end
        a.push(worker)
        consume a
      else
        _target_workers
      end

    var new_router: TargetIdRouter = StateStepRouter(_worker_name, _consumers,
      consume ps, _outgoing_boundaries, _stateless_partitions, tws)

    // If we have a reference to a consumer for this id, then we need to
    // remove it now.
    if _consumers.contains(id) then
      try
        let c = _consumers(id)?
        new_router = new_router.remove_consumer(id, c)
      else
        Unreachable()
      end
    end

    new_router

  fun val remove_proxy(id: RoutingId, worker: String, boundary: OutgoingBoundary):
    TargetIdRouter
  =>
    var removing_worker = true
    let ps = recover iso Map[RoutingId, ProxyAddress] end
    for (s_id, pa) in _proxies.pairs() do
      if s_id != id then
        if pa.worker == worker then removing_worker = false end
        ps(s_id) = pa
      end
    end
    let tws =
      if removing_worker then
        let a = recover iso Array[String] end
        for w in _target_workers.values() do
          if w != worker then
            a.push(w)
          end
        end
        consume a
      else
        _target_workers
      end
    StateStepRouter(_worker_name, _consumers, consume ps,
      _outgoing_boundaries, _stateless_partitions, tws)

  fun val update_boundaries(obs: Map[String, OutgoingBoundary] box):
    TargetIdRouter
  =>
    let m = recover iso Map[String, OutgoingBoundary] end
    for (w, b) in obs.pairs() do
      m(w) = b
    end
    StateStepRouter(_worker_name, _consumers, _proxies, consume m,
      _stateless_partitions, _target_workers)

  fun val update_stateless_partition_router(id: U128,
    pr: StatelessPartitionRouter): TargetIdRouter
  =>
    let sps = recover iso Map[U128, StatelessPartitionRouter] end
    for (s_id, r) in _stateless_partitions.pairs() do
      sps(s_id) = r
    end

    sps(id) = pr
    StateStepRouter(_worker_name, _consumers, _proxies, _outgoing_boundaries,
      consume sps, _target_workers)

  fun boundaries(): Map[String, OutgoingBoundary] val =>
    _outgoing_boundaries

  fun stateless_partition_ids(): Array[U128] val =>
    let a = recover iso Array[U128] end
    for id in _stateless_partitions.keys() do
      a.push(id)
    end
    consume a

  fun routes(): Map[RoutingId, Consumer] val =>
    let m = recover iso Map[RoutingId, Consumer] end
    for (id, c) in _consumers.pairs() do
      m(id) = c
    end
    for (id, pa) in _proxies.pairs() do
      try
        let ob = _outgoing_boundaries(pa.worker)?
        m(id) = ob
      else
        Fail()
      end
    end
    for spr in _stateless_partitions.values() do
      for (id, c) in spr.routes().pairs() do
        m(id) = c
      end
    end
    consume m

  fun routes_not_in(router: TargetIdRouter): Map[RoutingId, Consumer] val =>
    let m = recover iso Map[RoutingId, Consumer] end
    let other_routes = router.routes()
    for (id, c) in routes().pairs() do
      if not other_routes.contains(id) then m(id) = c end
    end
    consume m

  fun blueprint(): TargetIdRouterBlueprint =>
    let step_map = recover iso Map[RoutingId, ProxyAddress] end
    for (id, c) in _consumers.pairs() do
      step_map(id) = ProxyAddress(_worker_name, id)
    end
    for (id, pa) in _proxies.pairs() do
      step_map(id) = pa
    end
    let sp_blueprints =
      recover iso Map[RoutingId, StatelessPartitionRouterBlueprint] end
    for (p_id, sp) in _stateless_partitions.pairs() do
      sp_blueprints(p_id) = sp.blueprint()
    end
    StateStepRouterBlueprint(consume step_map, consume sp_blueprints)

  fun eq(that: box->TargetIdRouter): Bool =>
    match that
    | let ssr: StateStepRouter =>
      (_worker_name == ssr._worker_name) and
      MapTagEquality[RoutingId, Consumer](_consumers, ssr._consumers) and
      MapEquality[RoutingId, ProxyAddress](_proxies, ssr._proxies) and
      MapTagEquality[WorkerName, OutgoingBoundary](_outgoing_boundaries,
        ssr._outgoing_boundaries) and
      MapEquality[RoutingId, StatelessPartitionRouter](_stateless_partitions,
        ssr._stateless_partitions)
    else
      false
    end

trait val TargetIdRouterBlueprint
  fun build_router(worker_name: String,
    outgoing_boundaries: Map[String, OutgoingBoundary] val,
    local_sinks: Map[RoutingId, Consumer] val,
    auth: AmbientAuth): TargetIdRouter

class val EmptyTargetIdRouterBlueprint is TargetIdRouterBlueprint
  fun build_router(worker_name: String,
    outgoing_boundaries: Map[String, OutgoingBoundary] val,
    local_sinks: Map[RoutingId, Consumer] val,
    auth: AmbientAuth): TargetIdRouter
  =>
    EmptyTargetIdRouter

class val StateStepRouterBlueprint is TargetIdRouterBlueprint
  let _step_map: Map[RoutingId, ProxyAddress] val
  let _stateless_partition_routers:
    Map[U128, StatelessPartitionRouterBlueprint] val

  new val create(step_map: Map[RoutingId, ProxyAddress] val,
    stateless_partitions: Map[U128, StatelessPartitionRouterBlueprint] val)
  =>
    _step_map = step_map
    _stateless_partition_routers = stateless_partitions

  fun build_router(worker_name: String,
    outgoing_boundaries: Map[String, OutgoingBoundary] val,
    local_sinks: Map[RoutingId, Consumer] val,
    auth: AmbientAuth): TargetIdRouter
  =>
    let consumers = recover iso Map[RoutingId, Consumer] end
    let proxies = recover iso Map[RoutingId, ProxyAddress] end
    let target_workers = SetIs[String]
    for (id, pa) in _step_map.pairs() do
      if local_sinks.contains(id) then
        try
          consumers(id) = local_sinks(id)?
        else
          Fail()
        end
      else
        proxies(id) = pa
        target_workers.set(pa.worker)
      end
    end
    let stateless_rs = recover iso Map[U128, StatelessPartitionRouter] end
    for (p_id, sr) in _stateless_partition_routers.pairs() do
      stateless_rs(p_id) = sr.build_router(worker_name, outgoing_boundaries,
        auth)
    end

    let tws = recover iso Array[String] end
    for w in target_workers.values() do
      tws.push(w)
    end

    StateStepRouter(worker_name, consume consumers,
      consume proxies, outgoing_boundaries, consume stateless_rs,
      consume tws)

class val DataRouter is Equatable[DataRouter]
  let _worker_name: String
  let _data_routes: Map[RoutingId, Consumer] val
  let _state_steps: Map[StateName, Array[Step] val] val
  let _consumer_ids: MapIs[Consumer, RoutingId] val
  let _target_ids_to_route_ids: Map[RoutingId, RouteId] val
  let _route_ids_to_target_ids: Map[RouteId, RoutingId] val

  // Special RoutingIds that indicates that a barrier or register_producer
  // request needs to be forwarded to all known state steps on this workes.
  let _state_routing_ids: Map[RoutingId, StateName] val

  new val create(worker: String, data_routes: Map[RoutingId, Consumer] val,
    state_steps: Map[StateName, Array[Step] val] val,
    state_routing_ids': Map[RoutingId, StateName] val)
  =>
    _worker_name = worker
    _data_routes = data_routes
    _state_steps = state_steps
    _state_routing_ids = state_routing_ids'

    var route_id: RouteId = 0
    let ids: Array[RoutingId] = ids.create()
    let cid_map = recover trn MapIs[Consumer, RoutingId] end
    let tid_map = recover trn Map[RoutingId, RouteId] end
    let rid_map = recover trn Map[RouteId, RoutingId] end

    for step_id in _data_routes.keys() do
      ids.push(step_id)
    end
    for (r_id, c) in data_routes.pairs() do
      cid_map(c) = r_id
    end
    for id in Sort[Array[RoutingId], RoutingId](ids).values() do
      route_id = route_id + 1
      tid_map(id) = route_id
    end
    for (t_id, r_id) in tid_map.pairs() do
      rid_map(r_id) = t_id
    end

    _consumer_ids = consume cid_map
    _target_ids_to_route_ids = consume tid_map
    _route_ids_to_target_ids = consume rid_map

  fun size(): USize =>
    _data_routes.size()

  fun state_routing_ids(): Map[RoutingId, StateName] val =>
    _state_routing_ids

  fun step_for_id(id: RoutingId): Consumer ? =>
    _data_routes(id)?

  fun route(d_msg: DeliveryMsg, pipeline_time_spent: U64,
    producer_id: RoutingId, producer: DataReceiver ref, seq_id: SeqId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)
  =>
    ifdef "trace" then
      @printf[I32]("Rcvd msg at DataRouter\n".cstring())
    end
    try
      d_msg.deliver(pipeline_time_spent, producer_id, producer,
        seq_id, latest_ts, metrics_id, worker_ingress_ts,
        _data_routes, _state_steps, _consumer_ids,
        _target_ids_to_route_ids, _route_ids_to_target_ids)?
    else
      Fail()
    end

  fun replay_route(r_msg: ReplayableDeliveryMsg, pipeline_time_spent: U64,
    producer_id: RoutingId, producer: DataReceiver ref, seq_id: SeqId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)
  =>
    try
      r_msg.replay_deliver(pipeline_time_spent,
        _data_routes, _state_steps, _consumer_ids, _target_ids_to_route_ids,
        producer_id, producer, seq_id, latest_ts, metrics_id,
        worker_ingress_ts)?
    else
      Fail()
    end

  fun register_producer(input_id: RoutingId, output_id: RoutingId,
    producer: DataReceiver ref)
  =>
    if _data_routes.contains(output_id) then
      try
        _data_routes(output_id)?.register_producer(input_id, producer)
      else
        Unreachable()
      end
    elseif _state_routing_ids.contains(output_id) then
      try
        let state_name = _state_routing_ids(output_id)?
        let state_steps = _state_steps(state_name)?
        for step in state_steps.values() do
          step.register_producer(input_id, producer)
        end
      else
        Fail()
      end
    else
      producer.queue_register_producer(input_id, output_id)
    end

  fun unregister_producer(input_id: RoutingId, output_id: RoutingId,
    producer: DataReceiver ref)
  =>
    if _data_routes.contains(output_id) then
      try
        _data_routes(output_id)?.unregister_producer(input_id, producer)
      else
        Unreachable()
      end
    elseif _state_routing_ids.contains(output_id) then
      try
        let state_name = _state_routing_ids(output_id)?
        let state_steps = _state_steps(state_name)?
        for step in state_steps.values() do
          step.unregister_producer(input_id, producer)
        end
      else
        Fail()
      end
    else
      producer.queue_unregister_producer(input_id, output_id)
    end

  fun route_ids(): Array[RouteId] =>
    let ids: Array[RouteId] = ids.create()
    for id in _target_ids_to_route_ids.values() do
      ids.push(id)
    end
    ids

  fun routes(): Map[RoutingId, Consumer] val =>
    let m = recover iso Map[RoutingId, Consumer] end
    for (r_id, c) in _data_routes.pairs() do
      m(r_id) = c
    end
    consume m

  fun remove_routes_to_consumer(id: RoutingId, c: Consumer) =>
    """
    For all consumers we have routes to, tell them to remove any route to
    the provided consumer.
    """
    for consumer in _data_routes.values() do
      match consumer
      | let p: Producer =>
        p.remove_route_to_consumer(id, c)
      end
    end

  fun forward_barrier(target_step_id: RoutingId, origin_step_id: RoutingId,
    producer: Producer, barrier_token: BarrierToken)
  =>
    if _data_routes.contains(target_step_id) then
      try
        _data_routes(target_step_id)?.receive_barrier(origin_step_id,
          producer, barrier_token)
      else
        Unreachable()
      end
    elseif _state_routing_ids.contains(target_step_id) then
      try
        let state_name = _state_routing_ids(target_step_id)?
        let state_steps = _state_steps(state_name)?
        for step in state_steps.values() do
          step.receive_barrier(origin_step_id, producer, barrier_token)
        end
      else
        Fail()
      end
    else
      Fail()
    end

  fun eq(that: box->DataRouter): Bool =>
    MapTagEquality[U128, Consumer](_data_routes, that._data_routes) and
      MapEquality[U128, RouteId](_target_ids_to_route_ids,
        that._target_ids_to_route_ids) //and
      // MapEquality[RouteId, U128](_route_ids_to_target_ids,
      //   that._route_ids_to_target_ids)

  fun report_status(code: ReportStatusCode) =>
    for consumer in _data_routes.values() do
      consumer.report_status(code)
    end

trait val PartitionRouter is Router
  fun state_name(): String
  fun receive_key_state(key: Key, state: ByteSeq val)
  fun rebalance_steps_grow(auth: AmbientAuth,
    target_workers: Array[(String, OutgoingBoundary)] val,
    router_registry: RouterRegistry ref,
    local_keys: SetIs[Key],
    checkpoint_id: CheckpointId): (PartitionRouter, Bool)
  fun rebalance_steps_shrink(
    target_workers: Array[(String, OutgoingBoundary)] val,
    leaving_workers: Array[String] val,
    router_registry: RouterRegistry ref,
    local_keys: SetIs[Key],
    checkpoint_id: CheckpointId): Bool
  fun recalculate_hash_partitions_for_join(auth: AmbientAuth,
    joining_workers: Array[String] val,
    outgoing_boundaries: Map[String, OutgoingBoundary]): PartitionRouter
  fun recalculate_hash_partitions_for_shrink(
    leaving_workers: Array[String] val): PartitionRouter
  fun hash_partitions(): HashPartitions
  fun update_hash_partitions(hp: HashPartitions): PartitionRouter
  // Number of local steps in partition
  fun local_size(): USize
  fun update_boundaries(auth: AmbientAuth,
    ob: box->Map[String, OutgoingBoundary]): PartitionRouter
  fun add_state_routing_id(worker: WorkerName, routing_id: RoutingId):
    PartitionRouter
  fun blueprint(): PartitionRouterBlueprint
  fun distribution_digest(): Map[WorkerName, Array[String] val] val

class val LocalPartitionRouter[S: State ref] is PartitionRouter
  let _state_name: String
  let _worker_name: String
  let _state_steps: Array[Step] val
  let _step_ids: Map[RoutingId, Step] val
  let _consumer_ids: MapIs[Step, RoutingId] val
  let _hashed_node_routes: Map[String, HashedProxyRouter] val
  let _hash_partitions: HashPartitions
  let _state_routing_ids: Map[WorkerName, RoutingId] val

  new val create(state_name': StateName,
    worker_name: WorkerName,
    state_steps: Array[Step] val,
    step_ids: Map[RoutingId, Step] val,
    hashed_node_routes: Map[WorkerName, HashedProxyRouter] val,
    hash_partitions': HashPartitions,
    state_routing_ids: Map[WorkerName, RoutingId] val)
  =>
    _state_name = state_name'
    _worker_name = worker_name
    _state_steps = state_steps
    _step_ids = step_ids
    _hashed_node_routes = hashed_node_routes
    _hash_partitions = hash_partitions'
    _state_routing_ids = state_routing_ids
    let consumer_ids = recover iso MapIs[Step, RoutingId] end
    for (k, v) in _step_ids.pairs() do
      consumer_ids(v) = k
    end
    _consumer_ids = consume consumer_ids

  fun local_size(): USize =>
    _state_steps.size()

  fun state_name(): String =>
    _state_name

  fun route[D: Any val](metric_name: String, pipeline_time_spent: U64, data: D,
    producer_id: RoutingId, producer: Producer ref, i_msg_uid: MsgId,
    frac_ids: FractionalMessageId, latest_ts: U64, metrics_id: U16,
    worker_ingress_ts: U64): (Bool, U64)
  =>
    ifdef "trace" then
      @printf[I32]("Rcvd msg at PartitionRouter\n".cstring())
    end
    match data
    | let kw: KeyWrapper val =>
      let key = kw.key()
      let worker =
        try
          _hash_partitions.get_claimant_by_key(key)?
        else
          @printf[I32](("Could not find claimant for key " +
            " '%s'\n\n").cstring(), key.string().cstring())
          Fail()
          return (true, latest_ts)
        end
      if worker == _worker_name then
        try
          let idx = (HashKey(key) % _state_steps.size().u128()).usize()
          let s = _state_steps(idx)?
          let might_be_route = producer.route_to(s)
          match might_be_route
          | let r: Route =>
            ifdef "trace" then
              @printf[I32]("PartitionRouter found Route\n".cstring())
            end
            r.run[D](metric_name, pipeline_time_spent,
              data, producer_id, producer, i_msg_uid, frac_ids,
              latest_ts, metrics_id, worker_ingress_ts)
            (false, latest_ts)
          else
            // TODO: What do we do if we get None?
            Fail()
            (true, latest_ts)
          end
        else
          ifdef debug then
            @printf[I32](("LocalPartitionRouter.route: No state step for " +
              "key '%s'\n\n").cstring(), key.string().cstring())
          end
          Fail()
          (false, latest_ts)
        end
      else
        try
          let r = _hashed_node_routes(worker)?
          let msg = r.build_msg[D](metric_name, pipeline_time_spent, data,
            key, producer_id, producer, i_msg_uid, frac_ids, latest_ts,
            metrics_id, worker_ingress_ts)
          r.route[ForwardKeyedMsg[D]](metric_name, pipeline_time_spent, msg,
            producer_id, producer, i_msg_uid, frac_ids, latest_ts,
            metrics_id, worker_ingress_ts)
        else
          // We should have a route to any claimant we know about
          Fail()
          (true, latest_ts)
        end
      end
    else
      Fail()
      (true, latest_ts)
    end

  fun routes(): Map[RoutingId, Consumer] val =>
    let m = recover iso Map[RoutingId, Consumer] end
    for (id, step) in _step_ids.pairs() do
      m(id) = step
    end
    for (w, hpr) in _hashed_node_routes.pairs() do
      try
        m(_state_routing_ids(w)?) = hpr.target_boundary()
      else
        @printf[I32](("LocalPartitionRouter: Failed to find state routing " +
          "id for %s\n").cstring(), w.cstring())
        Fail()
      end
    end
    consume m

  fun routes_not_in(router: Router): Map[RoutingId, Consumer] val =>
    let diff = recover iso Map[RoutingId, Consumer] end
    let other_routes = router.routes()
    for (id, r) in routes().pairs() do
      if not other_routes.contains(id) then diff(id) = r end
    end
    consume diff

  fun update_boundaries(auth: AmbientAuth,
    ob: box->Map[String, OutgoingBoundary]): PartitionRouter
  =>
    let new_hashed_node_routes = recover trn Map[String, HashedProxyRouter] end

    for (w, hpr) in _hashed_node_routes.pairs() do
      new_hashed_node_routes(w) = hpr
    end
    for (w, b) in ob.pairs() do
      new_hashed_node_routes(w) = HashedProxyRouter(w, b, _state_name, auth)
    end

    LocalPartitionRouter[S](_state_name, _worker_name,
      _state_steps, _step_ids, consume new_hashed_node_routes,
      _hash_partitions, _state_routing_ids)

  fun receive_key_state(key: Key, state: ByteSeq val) =>
    let idx = (HashKey(key) % _state_steps.size().u128()).usize()
    try
      let step = _state_steps(idx)?
      step.receive_key_state(_state_name, key, state)
    else
      Fail()
    end

  fun recalculate_hash_partitions_for_join(auth: AmbientAuth,
    joining_workers: Array[String] val,
    outgoing_boundaries: Map[String, OutgoingBoundary]): PartitionRouter
  =>
    let new_hash_partitions =
      try
        _hash_partitions.add_claimants(joining_workers)?
      else
        Fail()
        _hash_partitions
      end
    let new_hashed_node_routes = recover trn Map[String, HashedProxyRouter] end
    for (w, pr) in _hashed_node_routes.pairs() do
      new_hashed_node_routes(w) = pr
    end
    for w in joining_workers.values() do
      try
        let b = outgoing_boundaries(w)?
        new_hashed_node_routes(w) = HashedProxyRouter(w, b, _state_name, auth)
      else
        Fail()
      end
    end

    LocalPartitionRouter[S](_state_name, _worker_name,
      _state_steps, _step_ids, consume new_hashed_node_routes,
      new_hash_partitions, _state_routing_ids)

  fun recalculate_hash_partitions_for_shrink(
    leaving_workers: Array[String] val): PartitionRouter
  =>
    let new_hash_partitions =
      try
        _hash_partitions.remove_claimants(leaving_workers)?
      else
        Fail()
        _hash_partitions
      end
    let new_hashed_node_routes = recover trn Map[String, HashedProxyRouter] end
    for (w, pr) in _hashed_node_routes.pairs() do
      if not ArrayHelpers[String].contains[String](leaving_workers, w) then
        new_hashed_node_routes(w) = pr
      end
    end

    LocalPartitionRouter[S](_state_name, _worker_name,
      _state_steps, _step_ids, consume new_hashed_node_routes,
      new_hash_partitions, _state_routing_ids)

  fun hash_partitions(): HashPartitions =>
    _hash_partitions

  fun update_hash_partitions(hp: HashPartitions): PartitionRouter =>
    LocalPartitionRouter[S](_state_name, _worker_name,
      _state_steps, _step_ids, _hashed_node_routes, hp,
      _state_routing_ids)

  fun rebalance_steps_grow(auth: AmbientAuth,
    target_workers: Array[(String, OutgoingBoundary)] val,
    router_registry: RouterRegistry ref,
    local_keys: SetIs[Key],
    checkpoint_id: CheckpointId): (PartitionRouter, Bool)
  =>
    """
    Begin migration of state steps known to this router that we determine
    must be routed. Return the new router and a Bool indicating whether
    we migrated any steps.
    """
    let new_workers_trn = recover trn Array[String] end
    let new_boundaries = Map[String, OutgoingBoundary]
    let keys_to_move = Array[Key]
    let keys_to_move_by_worker = Map[String, Array[Key]]
    for (w, b) in target_workers.values() do
      new_workers_trn.push(w)
      new_boundaries(w) = b
      keys_to_move_by_worker(w) = Array[Key]
    end
    let new_workers = consume val new_workers_trn

    let new_hash_partitions =
      try
        _hash_partitions.add_claimants(new_workers)?
      else
        Fail()
        _hash_partitions
      end

    // Determine the steps we need to migrate
    try
      for k in local_keys.values() do
        let c = new_hash_partitions.get_claimant_by_key(k)?
        if ArrayHelpers[String].contains[String](new_workers, c) then
          try
            keys_to_move.push(k)
            keys_to_move_by_worker(c)?.push(k)
          else
            Fail()
          end
        end
      end
    else
      Fail()
    end
    let steps_to_migrate = Array[(String, OutgoingBoundary, Key, RoutingId, Step)]
    for (w, ks) in keys_to_move_by_worker.pairs() do
      for k in ks.values() do
        try
          let boundary = new_boundaries(w)?
          let step_idx = (HashKey(k) % _state_steps.size().u128()).usize()
          let step = _state_steps(step_idx)?
          let step_id = _consumer_ids(step)?
          steps_to_migrate.push((w, boundary, k, step_id, step))
        else
          Fail()
        end
      end
    end

    // Update routes for the new PartitionRouter we will return
    let new_hashed_node_routes = recover trn Map[String, HashedProxyRouter] end

    for (w, pr) in _hashed_node_routes.pairs() do
      new_hashed_node_routes(w) = pr
    end
    for (w, b) in new_boundaries.pairs() do
      new_hashed_node_routes(w) = HashedProxyRouter(w, b, _state_name, auth)
    end

    // Actually initiate migration of steps
    let had_keys_to_migrate = migrate_keys(router_registry,
      steps_to_migrate, target_workers.size(), checkpoint_id)

    let new_router = LocalPartitionRouter[S](_state_name,
      _worker_name, _state_steps, _step_ids, consume new_hashed_node_routes,
      new_hash_partitions, _state_routing_ids)
    (new_router, had_keys_to_migrate)

  fun rebalance_steps_shrink(
    target_workers: Array[(String, OutgoingBoundary)] val,
    leaving_workers: Array[String] val,
    router_registry: RouterRegistry ref,
    local_keys: SetIs[Key],
    checkpoint_id: CheckpointId): Bool
  =>
    let remaining_workers_trn = recover trn Array[String] end
    let remaining_boundaries = Map[String, OutgoingBoundary]
    let keys_to_move = Map[String, Array[Key]]
    for (w, b) in target_workers.values() do
      remaining_workers_trn.push(w)
      remaining_boundaries(w) = b
      keys_to_move(w) = Array[Key]
    end
    let remaining_workers = consume val remaining_workers_trn

    let new_hash_partitions =
      try
        _hash_partitions.remove_claimants(leaving_workers)?
      else
        Fail()
        _hash_partitions
      end

    try
      for k in local_keys.values() do
        let c = new_hash_partitions.get_claimant_by_key(k)?
        if ArrayHelpers[String].contains[String](remaining_workers, c) then
          try
            keys_to_move(c)?.push(k)
          else
            Fail()
          end
        end
      end
    else
      Fail()
    end
    let steps_to_migrate = Array[(WorkerName, OutgoingBoundary, Key, RoutingId,
      Step)]
    for (w, ks) in keys_to_move.pairs() do
      for k in ks.values() do
        try
          let boundary = remaining_boundaries(w)?
          let step_idx = (HashKey(k) % _state_steps.size().u128()).usize()
          let step = _state_steps(step_idx)?
          let step_id = _consumer_ids(step)?
          steps_to_migrate.push((w, boundary, k, step_id, step))
        else
          Fail()
        end
      end
    end
    migrate_keys(router_registry, steps_to_migrate, target_workers.size(),
      checkpoint_id)

  fun migrate_keys(router_registry: RouterRegistry ref,
    keys_to_migrate': Array[(WorkerName, OutgoingBoundary, Key, RoutingId,
    Step)], target_worker_count: USize, checkpoint_id: CheckpointId): Bool
  =>
    """
    Actually initiate the migration of steps. Return false if none were
    migrated.
    """
    @printf[I32]("^^Migrating %lu keys to %d workers\n".cstring(),
      keys_to_migrate'.size(), target_worker_count)
    if keys_to_migrate'.size() > 0 then
      for (target_worker, boundary, key, step_id, step)
        in keys_to_migrate'.values()
      do
        router_registry.add_to_key_waiting_list(key)
        step.send_state(boundary, _state_name, key, checkpoint_id)
        @printf[I32](
          "^^Migrating key %s to outgoing boundary %s/%lx\n"
            .cstring(), key.cstring(), target_worker.cstring(), boundary)
      end
      true
    else
      false
    end

  fun add_state_routing_id(worker: WorkerName, routing_id: RoutingId):
    PartitionRouter
  =>
    let new_state_routing_ids = recover iso Map[WorkerName, RoutingId] end
    for (w, r_id) in _state_routing_ids.pairs() do
      new_state_routing_ids(w) = r_id
    end
    new_state_routing_ids(worker) = routing_id
    LocalPartitionRouter[S](_state_name, _worker_name, _state_steps,
      _step_ids, _hashed_node_routes, _hash_partitions,
      consume new_state_routing_ids)

  fun blueprint(): PartitionRouterBlueprint =>
    LocalPartitionRouterBlueprint[S](_state_name, _hash_partitions,
      _state_routing_ids)

  fun distribution_digest(): Map[WorkerName, Array[String] val] val =>
    // Return a map of form {worker_name: routing_ids_as_strings}
    let digest = recover iso Map[WorkerName, Array[String] val] end
    // First for this worker
    let a = recover iso Array[String] end
    for id in _step_ids.keys() do
      a.push(id.string())
    end
    digest(_worker_name) = consume a
    let others = Map[WorkerName, Array[String]]
    for (k, v) in others.pairs() do
      let next = recover iso Array[String] end
      for id in v.values() do
        next.push(id)
      end
      digest(k) = consume next
    end
    consume digest

  fun eq(that: box->Router): Bool =>
    match that
    | let o: box->LocalPartitionRouter[S] =>
        MapTagEquality[RoutingId, Step](_step_ids, o._step_ids) and
        (_hash_partitions == o._hash_partitions)
    else
      false
    end

  fun hash(): USize =>
    _state_name.hash()

trait val PartitionRouterBlueprint
  fun build_router(worker_name: String, workers: Array[String] val,
    state_steps: Array[Step] val, state_step_ids: Map[RoutingId, Step] val,
    outgoing_boundaries: Map[WorkerName, OutgoingBoundary] val,
    auth: AmbientAuth): PartitionRouter

class val LocalPartitionRouterBlueprint[S: State ref]
  is PartitionRouterBlueprint
  let _state_name: String
  let _hash_partitions: HashPartitions
  let _state_routing_ids: Map[WorkerName, RoutingId] val

  new val create(state_name: String, hash_partitions: HashPartitions,
    state_routing_ids: Map[WorkerName, RoutingId] val)
  =>
    _state_name = state_name
    _hash_partitions = hash_partitions
    _state_routing_ids = state_routing_ids

  fun build_router(worker_name: String, workers: Array[String] val,
    state_steps: Array[Step] val, state_step_ids: Map[RoutingId, Step] val,
    outgoing_boundaries: Map[WorkerName, OutgoingBoundary] val,
    auth: AmbientAuth): PartitionRouter
  =>
    let hashed_node_routes = recover trn Map[WorkerName, HashedProxyRouter] end
    for (w, b) in outgoing_boundaries.pairs() do
      hashed_node_routes(w) = HashedProxyRouter(worker_name, b, _state_name,
        auth)
    end
    let current_workers = Array[WorkerName]
    let joining_workers = recover trn Array[WorkerName] end
    for c in _hash_partitions.claimants() do
      current_workers.push(c)
    end
    for w in workers.values() do
      if not ArrayHelpers[String].contains[String](current_workers, w) then
        joining_workers.push(w)
      end
    end
    let new_hash_partitions =
      try
        _hash_partitions.add_claimants(consume joining_workers)?
      else
        Fail()
        _hash_partitions
      end

    LocalPartitionRouter[S](_state_name, worker_name,
      state_steps, state_step_ids, consume hashed_node_routes,
      new_hash_partitions, _state_routing_ids)

trait val StatelessPartitionRouter is Router
  fun partition_id(): RoutingId
  // // Total number of steps in partition
  fun size(): USize
  // Number of local steps in partition
  fun local_size(): USize
  fun update_boundaries(ob: box->Map[String, OutgoingBoundary]):
    StatelessPartitionRouter
  fun calculate_shrink(remaining_workers: Array[String] val):
    StatelessPartitionRouter
  fun blueprint(): StatelessPartitionRouterBlueprint
  fun distribution_digest(): Map[String, Array[String] val] val

class val LocalStatelessPartitionRouter is StatelessPartitionRouter
  let _partition_id: RoutingId
  let _worker_name: String
  // Maps sequential partition index to step id
  let _step_ids: Map[SeqPartitionIndex, RoutingId] val
  // Maps sequential partition index to step or proxy router
  let _partition_routes: Map[SeqPartitionIndex, (Step | ProxyRouter)] val
  let _steps_per_worker: USize
  let _partition_size: USize

  new val create(p_id: RoutingId, worker_name: String,
    s_ids: Map[SeqPartitionIndex, RoutingId] val,
    partition_routes: Map[SeqPartitionIndex, (Step | ProxyRouter)] val,
    steps_per_worker: USize)
  =>
    _partition_id = p_id
    _worker_name = worker_name
    _step_ids = s_ids
    _partition_routes = partition_routes
    _steps_per_worker = steps_per_worker
    _partition_size = _partition_routes.size()

  fun size(): USize =>
    _partition_size

  fun local_size(): USize =>
    _steps_per_worker

  fun partition_id(): RoutingId =>
    _partition_id

  fun route[D: Any val](metric_name: String, pipeline_time_spent: U64, data: D,
    producer_id: RoutingId, producer: Producer ref, i_msg_uid: MsgId,
    frac_ids: FractionalMessageId, latest_ts: U64, metrics_id: U16,
    worker_ingress_ts: U64): (Bool, U64)
  =>
    ifdef "trace" then
      @printf[I32]("Rcvd msg at StatelessPartitionRouter\n".cstring())
    end
    let stateless_partition_id = producer.current_sequence_id() % size().u64()

    try
      match _partition_routes(stateless_partition_id)?
      | let s: Step =>
        let might_be_route = producer.route_to(s)
        match might_be_route
        | let r: Route =>
          ifdef "trace" then
            @printf[I32]("StatelessPartitionRouter found Route\n".cstring())
          end
          r.run[D](metric_name, pipeline_time_spent, data,
            producer_id, producer, i_msg_uid, frac_ids, latest_ts, metrics_id,
            worker_ingress_ts)
          (false, latest_ts)
        else
          // TODO: What do we do if we get None?
          (true, latest_ts)
        end
      | let p: ProxyRouter =>
        p.route[D](metric_name, pipeline_time_spent, data, producer_id,
          producer, i_msg_uid, frac_ids, latest_ts, metrics_id,
          worker_ingress_ts)
      end
    else
      // Can't find route
      (true, latest_ts)
    end

  fun routes(): Map[RoutingId, Consumer] val =>
    let m = recover iso Map[RoutingId, Consumer] end

    for (p_id, s) in _partition_routes.pairs() do
      try
        let id = _step_ids(p_id)?
        match s
        | let step: Step =>
          m(id) = step
        | let pr: ProxyRouter =>
          for (r_id, r) in pr.routes().pairs() do
            m(r_id) = r
          end
        end
      else
        Fail()
      end
    end

    consume m

  fun routes_not_in(router: Router): Map[RoutingId, Consumer] val =>
    let diff = recover iso Map[RoutingId, Consumer] end
    let other_routes = router.routes()
    for (id, r) in routes().pairs() do
      if not other_routes.contains(id) then diff(id) = r end
    end
    consume diff

  fun update_boundaries(ob: box->Map[String, OutgoingBoundary]):
    StatelessPartitionRouter
  =>
    let new_partition_routes =
      recover trn Map[SeqPartitionIndex, (Step | ProxyRouter)] end
    for (p_id, target) in _partition_routes.pairs() do
      match target
      | let pr: ProxyRouter =>
        new_partition_routes(p_id) = pr.update_boundary(ob)
      else
        new_partition_routes(p_id) = target
      end
    end
    LocalStatelessPartitionRouter(_partition_id, _worker_name, _step_ids,
      consume new_partition_routes, _steps_per_worker)

  fun calculate_shrink(remaining_workers: Array[String] val):
    StatelessPartitionRouter
  =>
    // We need to remove any non-remaining workers from our partition
    // routes and then reassign partition ids accordingly. Partition ids
    // range sequentially from 0 to the partition count - 1.  They are
    // assigned to RoutingIds in the partition. When we remove non-remaining
    // workers, we are also removing all RoutingIds for partition steps that
    // existed on those workers. This means the partition count is reduced
    // and we create holes in the remaining valid partition ids. For example,
    // if we're removing worker 3 and worker 3 had a step corresponding to
    // partition ids 2 and 5 in a sequence from 0 to 5, then we are left
    // with partition id sequence [0, 1, 3, 4]. Since we route messages by
    // modding message seq ids over partition count, this gap means we'd
    // lose messages. We need to reassign the partition ids from 0 to
    // the new partition count - 1.
    let new_partition_count = remaining_workers.size() * _steps_per_worker

    // Filter out non-remaining workers, creating a map of only the
    // remaining partition routes.
    let reduced_partition_routes =
      recover trn Map[SeqPartitionIndex, (Step | ProxyRouter)] end
    for (seq_idx, s) in _partition_routes.pairs() do
      match s
      | let step: Step =>
        reduced_partition_routes(seq_idx) = step
      | let pr: ProxyRouter =>
        if remaining_workers.contains(pr.proxy_address().worker) then
          reduced_partition_routes(seq_idx) = pr
        end
      end
    end
    let partition_count = reduced_partition_routes.size()

    // Collect and sort the remaining old sequential partition indices.
    let unsorted_old_seq_idxs = Array[SeqPartitionIndex]
    for id in reduced_partition_routes.keys() do
      unsorted_old_seq_idxs.push(id)
    end
    let old_seq_idxs =
      Sort[Array[SeqPartitionIndex], SeqPartitionIndex](unsorted_old_seq_idxs)

    // Reassign SeqPartitionIndex and (Step | ProxyRouter) values to the new
    // partitions by placing them in new maps.
    let new_step_ids = recover trn Map[SeqPartitionIndex, RoutingId] end
    let new_partition_routes =
      recover trn Map[SeqPartitionIndex, (Step | ProxyRouter)] end
    for i in Range[SeqPartitionIndex](0, old_seq_idxs.size().u64()) do
      try
        let old_seq_idx = old_seq_idxs(i.usize())?
        new_step_ids(i) = _step_ids(old_seq_idx)?
        new_partition_routes(i) = reduced_partition_routes(old_seq_idx)?
      else
        Fail()
      end
    end

    LocalStatelessPartitionRouter(_partition_id, _worker_name,
      consume new_step_ids, consume new_partition_routes,
      _steps_per_worker)

  fun blueprint(): StatelessPartitionRouterBlueprint =>
    let partition_addresses =
      recover trn Map[SeqPartitionIndex, ProxyAddress] end
    try
      for (k, v) in _partition_routes.pairs() do
        match v
        | let s: Step =>
          let pr = ProxyAddress(_worker_name, _step_ids(k)?)
          partition_addresses(k) = pr
        | let pr: ProxyRouter =>
          partition_addresses(k) = pr.proxy_address()
        end
      end
    else
      Fail()
    end

    LocalStatelessPartitionRouterBlueprint(_partition_id, _step_ids,
      consume partition_addresses, _steps_per_worker)

  fun distribution_digest(): Map[String, Array[String] val] val =>
    // Return a map of form {worker_name: step_ids_as_strings}
    let digest = recover iso Map[String, Array[String] val] end
    // Accumulate step_ids per worker
    let others = Map[String, Array[String]]
    others(_worker_name) = Array[String]
    try
      for (seq_idx, target) in _partition_routes.pairs() do
        match target
        | let s: Step =>
          let step_id = _step_ids(seq_idx)?
          others(_worker_name)?.push(step_id.string())
        | let pr: ProxyRouter =>
          let pa = pr.proxy_address()
          if others.contains(pa.worker) then
            others(pa.worker)?.push(pa.routing_id.string())
          else
            let next = Array[String]
            next.push(pa.routing_id.string())
            others(pa.worker) = next
          end
        end
      end
    else
      Fail()
    end
    for (k, v) in others.pairs() do
      let next = recover iso Array[String] end
      for id in v.values() do
        next.push(id)
      end
      digest(k) = consume next
    end
    consume digest

  fun eq(that: box->Router): Bool =>
    match that
    | let o: box->LocalStatelessPartitionRouter =>
        MapEquality[SeqPartitionIndex, U128](_step_ids, o._step_ids) and
        _partition_routes_eq(o._partition_routes)
    else
      false
    end

  fun _partition_routes_eq(
    opr: Map[SeqPartitionIndex, (Step | ProxyRouter)] val): Bool
  =>
    try
      // These equality checks depend on the identity of Step or ProxyRouter
      // val which means we don't expect them to be created independently
      if _partition_routes.size() != opr.size() then return false end
      for (seq_idx, v) in _partition_routes.pairs() do
        match v
        | let s: Step =>
          if opr(seq_idx)? isnt v then return false end
        | let pr: ProxyRouter =>
          match opr(seq_idx)?
          | let pr2: ProxyRouter =>
            pr == pr2
          else
            false
          end
        end
      end
      true
    else
      false
    end

  fun hash(): USize =>
    _partition_id.hash()

trait val StatelessPartitionRouterBlueprint
  fun build_router(worker_name: String,
    outgoing_boundaries: Map[String, OutgoingBoundary] val,
    auth: AmbientAuth): StatelessPartitionRouter

class val LocalStatelessPartitionRouterBlueprint
  is StatelessPartitionRouterBlueprint
  let _partition_id: RoutingId
  let _step_ids: Map[SeqPartitionIndex, RoutingId] val
  let _partition_addresses: Map[SeqPartitionIndex, ProxyAddress] val
  let _steps_per_worker: USize

  new val create(p_id: RoutingId, s_ids: Map[SeqPartitionIndex, RoutingId] val,
    partition_addresses: Map[SeqPartitionIndex, ProxyAddress] val,
    steps_per_worker: USize)
  =>
    _partition_id = p_id
    _step_ids = s_ids
    _partition_addresses = partition_addresses
    _steps_per_worker = steps_per_worker

  fun build_router(worker_name: String,
    outgoing_boundaries: Map[String, OutgoingBoundary] val,
    auth: AmbientAuth): StatelessPartitionRouter
  =>
    let partition_routes =
      recover trn Map[SeqPartitionIndex, (Step | ProxyRouter)] end
    try
      for (k, pa) in _partition_addresses.pairs() do
        let proxy_router = ProxyRouter(pa.worker,
          outgoing_boundaries(pa.worker)?, pa, auth)
        partition_routes(k) = proxy_router
      end
    else
      Fail()
    end
    LocalStatelessPartitionRouter(_partition_id, worker_name, _step_ids,
      consume partition_routes, _steps_per_worker)

class val HashedProxyRouter is Router
  let _target_worker_name: String
  let _target: OutgoingBoundary
  let _target_state_name: String
  let _auth: AmbientAuth

  new val create(target_worker: String, target: OutgoingBoundary,
    target_state_name: String, auth: AmbientAuth)
  =>
    _target_worker_name = target_worker
    _target = target
    _target_state_name = target_state_name
    _auth = auth

  fun build_msg[D: Any val](metric_name: String, pipeline_time_spent: U64,
    data: D, key: Key, producer_id: RoutingId, producer: Producer ref,
    i_msg_uid: MsgId, frac_ids: FractionalMessageId, latest_ts: U64,
    metrics_id: U16, worker_ingress_ts: U64): ForwardKeyedMsg[D]
  =>
    ForwardKeyedMsg[D](
      _target_state_name,
      key,
      _target_worker_name,
      data,
      metric_name,
      i_msg_uid,
      frac_ids)

  fun route[D: Any val](metric_name: String, pipeline_time_spent: U64, data: D,
    producer_id: RoutingId, producer: Producer ref, i_msg_uid: MsgId,
    frac_ids: FractionalMessageId, latest_ts: U64, metrics_id: U16,
    worker_ingress_ts: U64): (Bool, U64)
  =>
    ifdef "trace" then
      @printf[I32]("Rcvd msg at HashedProxyRouter\n".cstring())
    end

    let might_be_route = producer.route_to(_target)
    match might_be_route
    | let r: Route =>
      ifdef "trace" then
        @printf[I32]("HashedProxyRouter found Route\n".cstring())
      end

      match data
      | let m: ReplayableDeliveryMsg =>
        r.forward(m, pipeline_time_spent, producer_id, producer,
          latest_ts, metrics_id, metric_name, worker_ingress_ts)
      else
        Fail()
      end

      (false, latest_ts)
    else
      Fail()
      (true, latest_ts)
    end

  fun routes(): Map[RoutingId, Consumer] val =>
    recover val Map[RoutingId, Consumer] end

  fun routes_not_in(router: Router): Map[RoutingId, Consumer] val =>
    recover val Map[RoutingId, Consumer] end

  fun val update_boundary(ob: box->Map[String, OutgoingBoundary]):
    HashedProxyRouter
  =>
    try
      let new_target = ob(_target_worker_name)?
      if new_target isnt _target then
        HashedProxyRouter(_target_worker_name, new_target,
          _target_state_name, _auth)
      else
        this
      end
    else
      Fail()
      this
    end

  fun target_boundary(): OutgoingBoundary =>
    _target

  fun eq(that: box->Router): Bool =>
    match that
    | let hpr: HashedProxyRouter =>
      (_target_worker_name == hpr._target_worker_name) and
        (_target is hpr._target)
    else
      false
    end

  fun hash(): USize =>
    _target_state_name.hash() xor (digestof _target).hash()
