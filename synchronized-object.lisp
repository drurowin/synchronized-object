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
  (:use :cl :bordeaux-threads)
  (:export #:set-read-lock
           #:release-read-lock
           #:set-access-lock
           #:release-access-lock
           #:with-locked-object
           #:synchronized-object-mixin))

(cl:in-package :org.drurowin.synchronized-object)

#+asdf
(eval-when (:compile-toplevel :load-toplevel :execute)
  (setf (documentation (find-package :org.drurowin.synchronized-object) t)
        (asdf:system-long-description (asdf:find-system :org.drurowin.synchronized-object))))
;;;;========================================================
;;;; API routines
(defgeneric set-read-lock (object &key timeout timeout-callback)
  (:documentation "Lock the object for read-only access.

If the lock cannot be acquired after timeout seconds and
timeout-callback is NIL or the keyword :SIGNAL, a timeout condition is
signalled.  When timeout-callback is a function designator, it is called
with no arguments before signalling the condition."))

(defgeneric release-read-lock (object)
  (:documentation "Unlock the object from read-only access."))

(defgeneric set-access-lock (object &key timeout timeout-callback)
  (:documentation "Lock the object for destructive access.

If the lock cannot be acquired after timeout seconds and
timeout-callback is NIL or the keyword :SIGNAL, a timeout condition is
signalled.  When timeout-callback is a function designator, it is called
with no arguments before signalling the condition."))

(defgeneric release-access-lock (object)
  (:documentation "Unlock the object from destructive access."))

(defmacro with-locked-object ((object &optional type &key timeout timeout-callback) &body body)
  "Evaluate the body forms with the object locked according to the lock
type.

The object is locked according to the lock type---one of NIL or :READ
for read-only locking (the default), or :ACCESS for destructive
locking---and the body forms are evaluated.  The object is unlocked upon
stack unwind."
  (check-type type (member nil :read :access))
  `(unwind-protect
        (progn (,(if (eql type :access) 'set-access-lock 'set-read-lock)
                ,object :timeout ,timeout :timeout-callback ,timeout-callback)
               ,@body)
     (,(if (eql type :access) 'release-access-lock 'release-read-lock)
      ,object)))

;;;;========================================================
;;;; implementation
(defclass synchronized-object-mixin ()
  ((thread-lock :initform (make-recursive-lock "thread lock"))
   (read-locks :initform ())
   (access-lock :initform nil))
  (:documentation "mixin class for objects that lock slot access"))

(defmacro with-object-thread-locking ((object &key timeout timeout-callback) &body body)
  (let ((start (gensym "START"))
        (time (gensym "TIME"))
        (gthlo (gensym "THREAD-LOCK"))
        (gto (gensym "TIMEOUT"))
        (gtocb (gensym "TIMEOUT-CALLBACK")))
    `(with-slots ((,gthlo thread-lock)) ,object
       (let ((,gto ,timeout)
             (,gtocb ,timeout-callback))
         (declare (type (or null (integer 1)) ,gto))
         (check-type ,gto (or null (integer 1)))
         (do ((,start (get-universal-time))
              (,time (get-universal-time) (get-universal-time)))
             ((and ,gto (>= (- ,time ,start) ,gto))
              (when (and ,gtocb
                         (or (functionp ,gtocb)
                             (and (symbolp ,gtocb)
                                  (not (keywordp ,gtocb)))))
                (funcall (if (functionp ,gtocb) ,gtocb (fdefinition ,gtocb)))))
           (handler-case
               (with-timeout (1)
                 (with-recursive-lock-held (,gthlo)
                   ,@body))
             (timeout () nil)))))))

(flet ((purge-dead-read-locks (o)
         (declare (type synchronized-object-mixin o))
         (setf (slot-value o 'read-locks)
               (remove-if-not #'thread-alive-p (slot-value o 'read-locks))))
       (purge-dead-access-lock (o)
         (declare (type synchronized-object-mixin o))
         (if (not (thread-alive-p (slot-value o 'access-lock)))
             (setf (slot-value o 'access-lock) nil)
             t)))
  (defmethod set-access-lock ((o synchronized-object-mixin) &key timeout timeout-callback)
    (with-slots (access-lock read-locks) o
      (with-object-thread-locking (o :timeout timeout :timeout-callback timeout-callback)
        (when (and (or (null access-lock)
                       (and access-lock (not (thread-alive-p access-lock)))
                       (eql access-lock (current-thread)))
                   (or (null read-locks)
                       (null (purge-dead-read-locks o))))
          (setf access-lock (current-thread))))))
  (defmethod set-read-lock ((o synchronized-object-mixin) &key timeout timeout-callback)
    (with-slots (access-lock read-locks) o
      (with-object-thread-locking (o :timeout timeout :timeout-callback timeout-callback)
        (when (or (null access-lock)
                  (null (purge-dead-access-lock o)))
          (pushnew (current-thread) read-locks))))))

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
    (unwind-protect
         (progn (unless (mutex-managed-slot-p slotd)
                  (set-read-lock object))
                (call-next-method))
      (unless (mutex-managed-slot-p slotd)
        (release-read-lock object))))
  (defmethod (setf closer-mop:slot-value-using-class) :around (value class (object synchronized-object-mixin) slotd)
    "Create an access lock for the duration of slot value setting."
    (unwind-protect
         (progn (unless (mutex-managed-slot-p slotd)
                  (set-access-lock object))
                (call-next-method))
      (unless (mutex-managed-slot-p slotd)
        (release-access-lock object)))))
