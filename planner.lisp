(in-package :tmsmt)


;;; ENCODING,
;;;  - PDDL Objects are state variables

(defun collect-args (objects arity)
  (if (zerop arity)
      (list nil)
      (loop for o in objects
         nconc
           (loop for args in (collect-args objects (1- arity))
              collect (cons o args)))))


(defun format-state-variable (predicate step)
  (format nil "~{~A~^_~}_~D" predicate step))

(defun format-op (op args step)
  (format nil "~A_~{~A~^_~}_~D" op args step))

(defun unmangle-op (mangled)
  (let ((list (ppcre:split "_" mangled)))
    (cons (parse-integer (lastcar list))
          (loop for x on list
             for a = (car x)
             when (cdr x)
             collect
             a))))

(defun create-state-variables (predicates objects)
  "Create all state variables from `PREDICATES' applied to `OBJECTS'"
  (let ((vars))
    (dolist (p predicates)
      ;; apply p to all valid arguments
      (dolist (args (collect-args objects (predicate-arity p)))
        (push (cons (predicate-name p) args)
              vars)))
    vars))

(defstruct concrete-action
  name
  actual-arguments
  precondition
  effect)

(defstruct concrete-state
  (bits (make-array 0 :element-type 'bit)))

(defun concrete-state-compare (a b)
  (let* ((a-bits (concrete-state-bits a))
         (b-bits (concrete-state-bits b))
         (n-a (length a-bits))
         (n-b (length b-bits)))
    (assert (= n-a n-b))
    (bit-vector-compare a-bits b-bits)))

(defun concrete-state-decode (state state-vars)
  (let ((bits (concrete-state-bits state)))
    (loop
       for b across bits
       for v in state-vars
       unless (zerop b)
       collect (list v
                     (if (zerop b) 'false 'true)))))

(defun state-vars-index (state-vars var)
  "Return the index of `VAR' in `STATE-VARS'."
  (let ((i (position var state-vars :test #'equal)))
    (assert i)
    i))

(defun state-vars-size (state-vars)
  (length state-vars))

(defun concrete-state-create (true-bits false-bits state-vars)
  (let ((bits (make-array (state-vars-size state-vars) :element-type 'bit)))
    (dolist (var true-bits)
      (setf (aref bits (state-vars-index state-vars var))
            1))
    (dolist (var false-bits)
      (setf (aref bits (state-vars-index state-vars var))
            0))
    (make-concrete-state :bits bits)))

(defun concrete-state-translate-exp (exp state-vars)
  "Return a lambda expression that evaluates `EXP'."
  (with-gensyms (state bits)
    `(lambda (,state)
       (let ((,bits (concrete-state-bits ,state)))
         ,(apply-rewrite-exp (lambda (v)
                               `(not (zerop (aref ,bits ,(state-vars-index state-vars v )))))
                             exp)))))

(defun concrete-state-compile-exp (exp state-vars)
  "Return a compiled lambda expression that evaluates `EXP'."
  (compile nil
           (concrete-state-translate-exp exp state-vars)))

(defun destructure-concrete-effect (thing)
  "Returns the effect as (values state-variable (or t nil))"
  (etypecase thing
      (atom (values thing t))
      (cons
       (destructuring-case thing
         (((and or) &rest args)
          (declare (ignore args))
          (error "Can't destructure ~A" thing))
         ((not x)
          (multiple-value-bind (state-variable sign) (destructure-concrete-effect x)
            (values state-variable (not sign))))
         ((t &rest x)
          (declare (ignore x))
          (values thing t))))))

(defun concrete-state-translate-effect (effect state-vars)
  "Return a lambda expression that creates a new state with `EFFECT' set."
  (with-gensyms (state bits new-bits)
    `(lambda (,state)
       (let* ((,bits (concrete-state-bits ,state))
              (,new-bits (make-array ,(state-vars-size state-vars) :element-type 'bit
                                     :initial-contents ,bits)))
         ,@(destructuring-bind (-and &rest things) effect
             (check-symbol -and 'and)
             (loop for exp in things
                collect
                  (multiple-value-bind (var sign)
                      (destructure-concrete-effect exp)
                    `(setf (aref ,new-bits ,(state-vars-index state-vars var))
                           ,(if sign 1 0)))))
         (make-concrete-state :bits ,new-bits)))))

(defun concrete-state-compile-effect (effect state-vars)
  "Return a compiled lambda expression that creates a new state with `EFFECT' set."
  (compile nil
           (concrete-state-translate-effect effect state-vars)))


(defun format-concrete-action (op step)
  (format-op (concrete-action-name op)
             (concrete-action-actual-arguments op)
             step))

(defun exp-args-alist (dummy-args actual-args)
  "Find alist for argument replacement"
  (assert (= (length dummy-args) (length actual-args)))
  (loop
     for d in dummy-args
     for a in actual-args
     collect (cons d a)))

(defun smt-concrete-actions (actions objects)
  (let ((result))
    (dolist (action actions)
      (dolist (args (collect-args objects
                                  (length (action-parameters action))))
        (let ((arg-alist (exp-args-alist (action-parameters action)
                                         args)))
          (push (make-concrete-action
                 :name (action-name action)
                 :actual-arguments args
                 :precondition (sublis arg-alist (action-precondition action))
                 :effect (sublis arg-alist (action-effect action)))
                result))))
    result))

;;(defun smt-encode-all-operators (operators step objects)
  ;;(let ((arg-set (collect-args objects (length (action-parameters operator)))))
  ;; collect operator instanciations
  ;; operator application axioms
  ;; exclusion axioms
  ;; frame axioms

(defun concrete-action-modifies-varable-p (action variable)
  (let ((not-variable (list 'not variable)))
    (destructuring-bind (-and &rest things) (concrete-action-effect action)
      (check-symbol -and 'and)
      (labels ((rec (rest)
                 (when rest
                   (let ((x (first rest)))
                     (if (or (equal x variable)
                             (equal x not-variable))
                         t
                         (rec (cdr rest)))))))
        (rec things)))))

(defun concrete-action-modified-variables (action)
  (destructuring-bind (-and &rest things) (concrete-action-effect action)
    (check-symbol -and 'and)
    (loop for exp in things
       collect
         (destructuring-case exp
           ((not x) x)
           ((t &rest rest) (declare (ignore rest))
            exp)))))

(defun smt-frame-axioms (state-vars concrete-actions step)
  ;(print concrete-operators)
  (let ((hash (make-hash-table :test #'equal))) ;; hash: variable => (list modifiying-operators)
    ;; note modified variables
    (dolist (op concrete-actions)
      (dolist (v (concrete-action-modified-variables op))
        (push op (gethash v hash))))
    ;; collect axioms

    ;(loop for var in state-vars
       ;do (print (gethash var hash)))
    (loop for var in state-vars
       collect
         (smt-assert (smt-or (list '=
                                   (format-state-variable var step)
                                   (format-state-variable var (1+ step)))
                             (apply #'smt-or
                                    (loop for op in (gethash var hash)
                                       collect (format-concrete-action op step))))))))



(defun smt-plan-encode (state-vars concrete-actions
                        initial-true initial-false
                        goal
                        steps)
  (let* ((smt-statements nil)
         (step-ops))
    (labels ((stmt (x)
               (push x smt-statements))
             (declare-step (x)
               (stmt (smt-declare-fun  x () 'bool))))
      ;; per-step state variables
      ;; create the per-step state
      (dotimes (i (1+ steps))
        (dolist (v state-vars)
          (declare-step (format-state-variable v i))))

      ;; per-step action variables
      (dotimes (i steps)
        (dolist (op concrete-actions)
          (let ((v (format-concrete-action op i)))
            (push v step-ops)
            (declare-step v ))))

      ;; initial state
      (dolist (p initial-true)
        (stmt (smt-assert (format-state-variable p 0))))
      (dolist (p initial-false)
        (stmt (smt-assert (smt-not (format-state-variable p 0)))))
      ;; goal state
      (stmt (smt-assert (rewrite-exp goal steps)))
      ;; operator encodings
      (dotimes (i steps)
        (dolist (op concrete-actions)
          (stmt (smt-assert `(or (not ,(format-op (concrete-action-name op)
                                                  (concrete-action-actual-arguments op)
                                                  i))
                                 (and ,(rewrite-exp (concrete-action-precondition op) i)
                                      ,(rewrite-exp (concrete-action-effect op) (1+ i))))))))


      ;; exclusion axioms
      (dotimes (i steps)
        (dolist (op concrete-actions)
          (stmt (smt-assert `(=> ,(format-op (concrete-action-name op)
                                             (concrete-action-actual-arguments op)
                                             i)
                                 (and ,@(loop for other-op in concrete-actions
                                           unless (eq op other-op)
                                           collect `(not ,(format-op (concrete-action-name other-op)
                                                                     (concrete-action-actual-arguments other-op)
                                                                     i)))))))))
      ;; frame axioms
      (dotimes (i steps)
        (map nil #'stmt (smt-frame-axioms state-vars concrete-actions i))))
    (values (reverse smt-statements)
            step-ops)))

(defun smt-plan-parse (assignments)
  (let ((plan))
    (dolist (x assignments)
      (destructuring-bind (var value) x
        (when (eq 'true value)
          (push (unmangle-op (string var)) plan))))
    (map 'list #'cdr (sort plan (lambda (a b) (< (car a) (car b)))))))

(defun smt-plan ( &key
                    operators facts
                    state-vars
                    concrete-actions
                    initial-true
                    initial-false
                    goal
                    (steps 1)
                    (max-steps 10))
  (let* ((operators (when operators
                      (load-operators operators)))
         (facts (when facts (load-facts facts)))
         (state-vars (or state-vars
                         (create-state-variables (operators-predicates operators)
                                                 (facts-objects facts))))
         (concrete-actions (or concrete-actions
                               (smt-concrete-actions (operators-actions operators)
                                                      (facts-objects facts))))
         (initial-true (or initial-true (facts-init facts)))
         (initial-false (or initial-false
                            (set-difference  state-vars initial-true :test #'equal)))
         (goal (or goal (facts-goal facts))))
    (labels ((rec (steps)
               (multiple-value-bind (assignments is-sat)
                   (multiple-value-bind (stmts vars)
                       (smt-plan-encode state-vars concrete-actions
                                        initial-true initial-false
                                        goal
                                        steps)
                     (smt-run stmts vars))
                     (cond
                       (is-sat
                        (smt-plan-parse assignments))
                       ((< steps max-steps)
                        (rec (1+ steps)))
                       (t nil)))))
      (rec steps))))


(defun plan-automaton (&key operators facts)
  (let* ((operators (load-operators operators))
         (facts (load-facts facts))
         (smt-statements nil)
         (state-vars (create-state-variables (operators-predicates operators)
                                              (facts-objects facts)))
         (controllable-actions (loop for a in (operators-actions operators)
                                   unless (action-uncontrollable a) collect a))
         (uncontrollable-actions (loop for a in (operators-actions operators)
                                     when (action-uncontrollable a) collect a))
         (concrete-controllable (smt-concrete-actions controllable-actions (facts-objects facts)))
         (concrete-uncontrollable (smt-concrete-actions uncontrollable-actions (facts-objects facts)))
         (uncontrollable-preconditions
          (loop for a in concrete-uncontrollable
             collect (concrete-state-compile-exp (concrete-action-precondition a)
                                                 state-vars)))
         (uncontrollable-effects
          (loop for a in concrete-uncontrollable
             collect (concrete-state-compile-effect (concrete-action-effect a)
                                                    state-vars)))
         (controllable-effects-hash (fold (lambda (hash action)
                                            (let ((key (cons (string (concrete-action-name action))
                                                             (map 'list #'string
                                                                  (concrete-action-actual-arguments action)))))

                                              (print key)
                                              (setf (gethash key hash)
                                                    (concrete-state-compile-effect (concrete-action-effect action)
                                                                                   state-vars))
                                              hash))
                                          (make-hash-table :test #'equal)
                                          concrete-controllable))
         (step-ops))
    ;(labels ((rec (start automata-states automata-edges)

    ;; 0. Generate Initial Plan
    (labels ((add-plan (states edges start plan))
             (controllable-effect (state action)
               (funcall (gethash action controllable-effects-hash)
                        state))
             (plan-states (start plan)
               (loop for a in plan
                  for s = (controllable-effect start a) then (controllable-effect s a)
                    collect s)))
      (let ((plan-0 (smt-plan :state-vars state-vars :concrete-actions concrete-controllable
                              :initial-true (facts-init facts) :goal (facts-goal facts)))
            (concrete-start (concrete-state-create (facts-init facts)
                                                   (set-difference state-vars (facts-init facts) :test #'equal)
                                                   state-vars)))
        (values plan-0 concrete-start
                (map 'list (lambda (s) (concrete-state-decode s state-vars))
                     (plan-states concrete-start plan-0)))
      ;(values plan-0 concrete-start)
      )

  ;; 1. Generate Plan
  ;; 2. Identify states with uncontrollable actions
  ;; 3. If uncontrollable effect is outside automata states,
  ;;    recursively solve from effect state back to automaton
  ;;    3.a If no recursive solution, restart with constraint to avoid
  ;;    the uncontrollable precondition state.
  ;; 4. When no deviating uncontrollable effects, return the automaton

    )))

;; (defun smt-print-exp (sexp &optional (stream *standard-output*))
;;   (etypecase sexp
;;     (null (format stream " () "))
;;     (list
;;      (destructuring-case sexp
;;        ((|not| exp) ;;         (format stream "~&(not")
;;         (smt-print-exp exp)
;;         (princ ")" stream))
;;        ((t &rest ignore)
;;         (declare (ignore ignore))
;;         (format stream "~&(")
;;         (dolist (sexp sexp) (smt-print-exp sexp))
;;         (princ ")" stream))))
;;     (symbol (format stream " ~A " sexp))
;;     (string (format stream " ~A " sexp))))