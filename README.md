[![Build Status](https://travis-ci.org/cloudfoundry/health_manager.png)](https://travis-ci.org/cloudfoundry/health_manager)

# HealthManager 2.0

Health Manager 2.0 (HM-2) is a complete re-write of the original Health
Manager.

HM-2 monitors the state of the applications and ensures that started
applications are indeed running, their versions and number of
instances correct.

Conceptually, this is done by maintaining a Known State of
applications and comparing it against the Expected State. When
discrepancies are found, actions are initiated to bring the
applications to the Expected State, e.g., start/stop commands are
issued for missing/extra instances, respectively.

Additionally, Health Manager collects and exposes statistics and
health status for individual applications, as well as aggregates for
frameworks, runtimes, etc.

## AppState

The state of each application is represented by an instance of an
aptly named class AppState. AppState gets forwarded important
state-changing messages (i.e. hearbeats and exit signals), updates its
internal state accordingly and then invokes registered event
handlers. It is the job of these handlers (housed in the Harmonizer,
see below) to enforce complex policies, e.g., whether to restart
application, if so, with which priority, etc.

## Components

HM-2 comprises the following components:

- Manager
- Harmonizer
- Scheduler
- ExpectedStateProvider
- KnownStateProvider
- Nudger
- Reporter
- Shadower

### Manager

Provides an entry point, configures, initializes and registers other
components.

### Harmonizer

Expresses the policy of bringing the applications to the Expected
State by observing the Known State.

Harmonizer sets up the interactions between other components, and aims
to achieve clarity of the intent through delegation:

Known State and Expected State are compared periodically with the use
of the Scheduler and Nudger actions are Scheduled to bring the States
into harmony.

### Scheduler

Encapsulates EventMachine-related functionality such as timer setup
and cancellation, quantization of long-running tasks to prevent EM
Reactor loop blocking.

### Expected State Provider

Provides the expected state of the application, e.g., whether the
application was Started or Stopped, how many instances should be
running, etc. This information comes from the Cloud Controller by way
of http-based Bulk API, hence the concrete class is
BulkBasedExpectedStateProvider

### Known State Provider

The Known state will be discovered from NatsBasedKnownStateProvider,
that will listen to heartbeat and other messages on the NATS bus.

The State of each application is represented by an instant of object
AppState. That object receives updates of the application state,
stores them and notifies registered listeners about events, such as
`instances_missing`, etc.

### Nudger

Nudger is the interface for health manager to effect the change on the
world, by dispatching `cloudcontrollers.hm.requests` messages
that instruct CCs to start or stop instances. Nudger maintains a
priority queue of these requests, and deques the messages by a
batchful.

### Reporter

Reporter responds to `healthmanager.status` and `healthmanager.health`
requests.

### Shadower

The Shadower component exists primarily to smoothen the transition from the
original HealthManager to this new HealthManager 2.0

The Shadower implements shadow-mode for HM-2, where it quietly and
passively observes the state of the world and comes up with
harmonization decisions, but rather than publishing harmonization
messages on the NATS bus, it keeps track of them. It also listens for
harmonization messages (most likely coming from the original
HealthManager) and compares those messages with the ones HM-2 has
produced. Ideally, these two sets of messages should perfectly
overlap. When they don't, shadower issues warnings.

When in shadow-mode, all outgoing messages are sent to the Shadower,
rather than being published to NATS.


## Harmonization Policy in Detail

Conceptually, harmonization happens in two ways:

- by reacting to messages (such as `droplet.exited`);
- by periodically scanning the world and enumerating applications,
  looking for anomalies.

### droplet.exited signal

There are three distinct scenarios possible when `droplet.exited`
signal arrives:

- application is stopped; means the application was stopped
  explicitly, no action required;

- DEA evacuation; the DEA is being evacuated and all instances from that DEA
  need to be restarted somewhere else. HM-2 initiates that restarting;

- application instance crashed; That instance needs to be restarted unless it
  crashed multiple times in short period of time, in which case it is
  declared `flapping`. See more on this below.

### `flapping` instances

An instance of application is declared `flapping` if it crashed more
than `flapping_death` times within `flapping_timeout` seconds. There
are several possible reasons for flapping:

- app is completely broken and simply does not start;
- app has a bug that results in a crash every once in a while;
- app has a dependency on the external world or a CF-provisioned
  service, and that dependency is unavailable, perhaps temporarily,
  resulting in app repeatedly crashing.

Handling flapping apps is hard. We'd like to:

- make the best effort to restart an app, when it makes sense;
- provide the crashlogs for crashing instances;
- cut down on the overhead associated with restarting an
  app, particularly relating to moving application bits to DEA and
  storing it there.
- avoid IO spikes due to massive simultaneous restarts

In order to accomodate these conflicting requirements, the following
policy for flapping instances (FI) adopted:

- initially the FI is restarted with a delay defined by `min_restart_delay` config value;
- for each subsequent crash, the delay is doubled, but not to exceed `max_restart_delay` config value;
- a random noise is added to the value of delay, its maximum absolute value defined by
  `delay_time_noise` config value;
- if the number of crashes for a given FI exceeds `giveup_crash_number`, give up restarting attempts.
  This behavior can be turned off.

### Heartbeat processing

DEAs peridically send out heartbeat messages on NATS bus. These
heartbeats contain DEA identifying information, as well as information
on application instances running on respective DEAs.

The heartbeats are used to establish "missing" and "extra"
indices. Missing indices are then commanded to start, extra indices
are commanded to stop.

AppState object tracks heartbeats for each instance of each version.

An instance is "missing" if a live version of this instance has not
received a heartbeat in the last `droplet_lost` seconds.

However, an instance_missing event is only triggered if the AppState
was not reset recently, and if `check_for_missing_instances` method
has been invoked.
