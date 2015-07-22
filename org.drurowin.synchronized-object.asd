(asdf:defsystem :org.drurowin.synchronized-object
  :author "Lucien Pullen"
  :mailto "drurowin@gmail.com"
  :description "read and write object synchronization"
  :long-description "Read and write synchronization of CLOS instances.

Object synchronization allows multithreaded applications to lock
instances.  This goes beyond simple locking, or 'access' locks.  This
library provides two classes of locking: access and read-only locks.

Access locks are locks that prevent other threads from doing anything
with the object.  They are useful for performing destructive
modification of the object (or a resource that the object tracks).
Read-only locks prevent destructive interaction with the object while
allowing non-destructive interaction to occur.

The basic entrypoint for synchronized objects is to create a class with
the `synchronized-object-mixin' class as a parent class.  Slot access
locking is automatically provided.  The program may easily extend
functionality by using the `set-*-lock' and `release-*-lock' functions
and the `with-locked-object' macro in API routines.

The lock set and release functions are provided as generic functions for
further, low-level extension."
  :depends-on (:bordeaux-threads :closer-mop)
  :components ((:file "synchronized-object")))
