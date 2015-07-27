;; org.drurowin.synchronized-object
;; Copyright (c) 2015 Lucien Pullen <drurowin@gmail.com>
;;
;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
;; THE SOFTWARE.
(cl:defpackage :org.drurowin.synchronized-object
  (:use :cl :bordeaux-threads :org.drurowin.timeout)
  (:export #:acquire-read-lock
           #:release-read-lock
           #:acquire-access-lock
           #:release-access-lock
           #:with-locked-object
           #:synchronized-object-mixin))

(cl:in-package :org.drurowin.synchronized-object)

#+asdf
(eval-when (:compile-toplevel :load-toplevel :execute)
  (setf (documentation (find-package :org.drurowin.synchronized-object) t)
        (asdf:system-long-description (asdf:find-system :org.drurowin.synchronized-object))))

(defparameter %indentation% (make-hash-table))

#+swank
(eval-when (:load-toplevel :execute)
  (pushnew %indentation% swank::*application-hints-tables*))
;;;;========================================================
;;;; API routines
(defgeneric acquire-read-lock (object &optional timeout callback)
  (:documentation "Lock the object for read-only access.  On success, true is returned.

Multiple threads may acquire a read-only lock.  The lock cannot be
acquired if an access lock (see `acquire-access-lock') is held by
another thread.

When timeout is non-NIL, the given number of seconds (including zero, to
return immediately) are waited before giving up acquiring the lock.  In
this case, NIL is returned.  Callback can be a function designator to
call when the timeout fails."))

(defgeneric acquire-access-lock (object &optional timeout callback)
  (:documentation "Lock the object for destructive access.  On success, true is returned.

Only one thread may acquire an access lock.  The lock cannot be acquired
if another access lock is held or any read-only locks (see
`acquire-read-lock') are held.

It is an error for a thread to attempt to acquire an access lock on an
object that it already owns a read-only lock on.

When timeout is non-NIL, the given number of seconds (including zero, to
return immediately) are waited before giving up acquiring the lock.  In
this case, NIL is returned.  Callback can be a function designator to
call when the timeout fails."))

(defgeneric release-read-lock (object)
  (:documentation "Unlock the object from read-only state."))

(defgeneric release-access-lock (object)
  (:documentation "Unlock the object from destructive state."))

(defmacro with-locked-object ((object &optional type timeout callback) &body body)
  "{ (object &optional type timeout callback) body... }

Evaluate the body forms with the object locked according to the lock
type.

The object is locked according to the lock type---one of NIL or :READ
for read-only locking (the default) (see `acquire-read-lock'),
or :ACCESS for destructive locking (see `acquire-access-lock')---during
the execution of the body forms."
  `(call/locked-object (lambda () ,@body) ,object ,type ,timeout ,callback))

;;;;========================================================
;;;; implementation
(defclass synchronized-object-mixin ()
  ((thread-lock :initform (make-recursive-lock "thread lock"))
   (read-locks :initform ())
   (access-lock :initform nil))
  (:documentation "mixin class for objects that lock slot access"))

(declaim (ftype (function (function
                           t
                           (member :read :access)
                           &optional
                           (or null (integer 0))
                           (or null (and symbol (not keyword)) function)))
                call/locked-object))
(defun call/locked-object (thunk object type &optional timeout callback)
  (flet ((acquire-lock ()
           (if (eql type :read)
               (acquire-read-lock object 0)
               (acquire-access-lock object 0))))
    (do-until-timeout (timeout callback)
        ((lockedp (acquire-lock) (acquire-lock)))
        (lockedp
         (when lockedp
           (unwind-protect (funcall thunk)
             (if (eql type :read)
                 (release-read-lock object)
                 (release-access-lock object))))))))

(defmacro with-object-thread-locking ((object) &body body)
  (let ((gthlo (gensym "THREAD-LOCK")))
    `(if (slot-boundp ,object 'thread-lock)
         (with-slots ((,gthlo thread-lock)) ,object
           (with-recursive-lock-held (,gthlo)
             ,@body))
         (progn ,@body))))

(flet ((purge-dead-read-locks (o)
         (declare (type synchronized-object-mixin o))
         (setf (slot-value o 'read-locks)
               (remove-if-not #'thread-alive-p (slot-value o 'read-locks))))
       (purge-dead-access-lock (o)
         (declare (type synchronized-object-mixin o))
         (if (not (thread-alive-p (slot-value o 'access-lock)))
             (setf (slot-value o 'access-lock) nil)
             t)))
  (defmethod acquire-read-lock ((o synchronized-object-mixin) &optional timeout callback)
    (check-type timeout (or null (integer 0)))
    (check-type callback (or null function (and symbol (not keyword))))
    (with-slots (access-lock read-locks) o
      (do-until-timeout (timeout callback)
          ((lockedp nil))
          (lockedp lockedp)
        (with-object-thread-locking (o)
          (cond ((eql access-lock (current-thread))
                 (setf lockedp t))
                ((or (null access-lock)
                     (null (purge-dead-access-lock o)))
                 (pushnew (current-thread) read-locks)
                 (setf lockedp t)))))))
  (defmethod acquire-access-lock ((o synchronized-object-mixin) &optional timeout callback)
    (with-slots (access-lock read-locks) o
      (do-until-timeout (timeout callback)
          ((lockedp nil))
          (lockedp lockedp)
        (with-object-thread-locking (o)
          (when (find (current-thread) read-locks)
            (error "Attempting to acquire access lock while thread owns read-only lock."))
          (when (and (or (null access-lock)
                         (and access-lock (not (thread-alive-p access-lock)))
                         (eql access-lock (current-thread)))
                     (or (null read-locks)
                         (null (purge-dead-read-locks o))))
            (setf access-lock (current-thread))
            (setf lockedp t)))))))

(defmethod release-access-lock ((o synchronized-object-mixin))
  (with-slots (thread-lock access-lock) o
    (with-recursive-lock-held (thread-lock)
      (when (eql access-lock (current-thread))
        (setf access-lock nil)
        t))))

(defmethod release-read-lock ((o synchronized-object-mixin))
  (with-slots (thread-lock read-locks) o
    (with-recursive-lock-held (thread-lock)
      (setf read-locks (remove (current-thread) read-locks))
      t)))

(flet ((mutex-managed-slot-p (o)
         (find (closer-mop:slot-definition-name o) '(thread-lock read-locks access-lock))))
  (defmethod closer-mop:slot-value-using-class :around (class (object synchronized-object-mixin) slotd)
    "Create a read-only lock for the duration of slot value fetching."
    (if (and (slot-boundp object 'thread-lock)
             (slot-boundp object 'read-locks)
             (slot-boundp object 'access-lock)
             (not (mutex-managed-slot-p slotd)))
        (with-locked-object (object :read)
          (call-next-method))
        (call-next-method)))
  (defmethod (setf closer-mop:slot-value-using-class) :around (value class (object synchronized-object-mixin) slotd)
    "Create an access lock for the duration of slot value setting."
    (if (and (slot-boundp object 'thread-lock)
             (slot-boundp object 'read-locks)
             (slot-boundp object 'access-lock)
             (not (mutex-managed-slot-p slotd)))
        (with-locked-object (object :access)
          (call-next-method))
        (call-next-method))))
