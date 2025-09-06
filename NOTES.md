# Notes

## Definitions

- User: owner of resources & data
- Application: agent identity which can borrow resources/data from a user
  (or multiple users?)
  - Application can be composed of many programs/processes
  - Multiple "applications" can share the same source code. The apps do the
    same thing, but the resources they can access are separate
  - Needs to be granted access to every resource. That includes compute/RAM.
    Maybe applications can be auto-granted some set amount so that user's don't
    have to explicitly set computing bounds.
  - Linked to a specific user? Other option is to specify which user to request
    access from (maybe with a default)
  - Runs on behalf of a user? OS processes need to start before a user is
    authenticated, so maybe this doesn't need to be the case. Or there could be
    a "root" user for which OS processes run
- Process: collection of resource handles
  - Single address space?
  - Can have multiple threads/vCPUs
  - Runs as part of an application
  - Parent/child relationship between processes OR all processes considered
    peers in application?
- Program: stored code/data that can be executed
  - Not necessarily on filesystem. Could be loaded from the current process's
    memory or the network. Needs some interface that loads (dynamically?) RAM
    pages.
- Operating System: application responsible for running processes and mediating
  resource access
  - Ideally, it's "just" an application
  - Not linked to a "real" user. Maybe linked to _all_ users?
  - Has full access to all resources
- IPC Message: message sent from one application to another
  - Every process and app has a unique address. Only app address is reachable
    without prior communication.
    - "app address" just points directly to one of its processes?
    - app address has special handling so that it can dispatch to processes
      by message type?
  - Can have opaque "return address". Maybe this doesn't even need to be
    a part of the protocol, and can just be in the payload if needed. That
    allows having multiple return addresses
  - Do IPC messages need to be allowed by OS? Sounds like a lot of extra work
    to verify that the sender can talk to the receiver.
  - Something like D-Bus activation, where a message can start an app or a
    process in an app?
- Kernel: processes, direct I/O, and IPC
  - Manage clock as well?
  - No identities, just processes?
    - Identities can be defined/checked by an application
  - Minimal resource access
  - syscalls for:
    - low-level I/O
    - Requesting RAM pages
    - managing processes
    - IPC

## Process

- Memory map
- Direct I/O handles?
- Thread/vCPU states
- IPC message queue
