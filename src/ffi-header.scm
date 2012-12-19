
;;; C constants generation macro

;; Creating the bindings in a simple C function makes for more compact
;; binaries, as per Marc Feeley's advice.
;;
;; https://mercure.iro.umontreal.ca/pipermail/gambit-list/2012-February/005688.html
;; (Via 'Alvaro Castro-Castilla).
(##define-macro
  (c-constants . names)
  (let ((nb-names (length names))
        (wrapper (gensym)))
    (letrec ((interval (lambda (lo hi)
                         (if (< lo hi) (cons lo (interval (+ lo 1) hi)) '()))))
      `(begin
         (##define ,wrapper
           (c-lambda (int)
                     int
                     ,(string-append
                       "static int _tmp_[] = {\n"
                       (apply string-append
                              (map (lambda (i name)
                                     (let ((name-str (symbol->string name)))
                                       (string-append
                                        (if (> i 0) "," "")
                                        name-str)))
                                   (interval 0 nb-names)
                                   names))
                       "};\n"
                       "___result = _tmp_[___arg1];\n")))
         ,@(map (lambda (i name)
                  `(##define ,name (,wrapper ,i)))
                (interval 0 nb-names)
                names)))))

;;; Struct and union generation macro
;;; (code by Estevo Castro)

(##define-macro (eval-in-macro-environment . exprs)
  (if (pair? exprs)
      (eval (if (null? (cdr exprs)) (car exprs) (cons 'begin exprs))
            (interaction-environment))
      #f))

(##define-macro (eval-in-macro-environment-no-result . exprs)
  `(eval-in-macro-environment
    ,@exprs
    '(begin)))

(##define-macro (##define^ . args)
  (let ((pattern (car args))
        (body (cdr args)))
    `(eval-in-macro-environment-no-result
      (##define ,pattern ,@body))))


; https://mercure.iro.umontreal.ca/pipermail/gambit-list/2009-August/003781.html
(##define-macro (at-expand-time-and-runtime . exprs)
  (let ((l `(begin ,@exprs)))
    (eval l)
    l))

(##define-macro (at-expand-time . expr)
  (eval (cons 'begin expr)))


(##define (c-native struct-or-union type fields)
  (define (to-string x)
    (cond ((string? x) x)
          ((symbol? x) (symbol->string x))
          (else (error "Unsupported type: " x))))
  (define (mixed-append . args) (apply string-append (map to-string args)))
  (define (symbol-append . args)
    (string->symbol (apply mixed-append args)))
  (define managed-prefix "managed-")
  (define unmanaged-prefix "unmanaged-")
  (pp struct-or-union)
  (pp type)
  (pp fields)
  (let*
      ((scheme-type (if (pair? type) (car type) type))
       (pointer-type (symbol-append scheme-type "*"))
       (c-type (if (pair? type) (cadr type) type))
       (c-type-name (symbol->string c-type))
       (attr-worker
        (lambda (fn)
          (lambda (field)
            (let* ((attr (car field))
                   (scheme-attr-name (symbol->string (if (pair? attr)
                                                         (car attr)
                                                         attr)))
                   (c-attr-name (symbol->string (if (pair? attr)
                                                    (cadr attr)
                                                    attr)))
                   (attr-type (cadr field))
                   (scheme-attr-type (if (pair? attr-type)
                                         (car attr-type)
                                         attr-type))
                   (c-attr-type (if (pair? attr-type)
                                    (cadr attr-type)
                                    attr-type))
                   (access-type (if (null? (cddr field))
                                    'scalar
                                    (caddr field)))
                   (voidstar (eq? access-type 'voidstar))
                   (pointer (eq? access-type 'pointer)))
              (fn scheme-attr-name
                  c-attr-name
                  scheme-attr-type
                  c-attr-type
                  voidstar
                  pointer)))))
       (accessor
        (attr-worker
         (lambda (scheme-attr-name c-attr-name scheme-attr-type c-attr-type
                              voidstar pointer)
           (let ((_voidstar (if (or voidstar pointer) "_voidstar" ""))
                 (amperstand (if voidstar "&" ""))
                 (scheme-attr-type (if voidstar
                                       (symbol-append unmanaged-prefix
                                                      scheme-attr-type)
                                       scheme-attr-type)))
             `(##define (,(symbol-append scheme-type
                                         "-"
                                         scheme-attr-name)
                         parent)
                (let ((ret
                       ((c-lambda
                         (,scheme-type) ,scheme-attr-type
                         ,(string-append
                           "___result" _voidstar
                                        ; XXX: correctly cast to type, should help with enums in C++.
                                        ;" = (" (symbol->string c-attr-type) ")"
                           " = "
                           amperstand "(((" c-type-name
                           "*)___arg1_voidstar)->"
                           c-attr-name ");"))
                        parent)))
                  ,@(if voidstar
                        '((ffi:link parent ret))
                        '())
                  ret))))))
       (mutator
        (attr-worker
         (lambda (scheme-attr-name c-attr-name scheme-attr-type c-attr-type
                              voidstar pointer)
           (let ((_voidstar (if (or voidstar pointer) "_voidstar" ""))
                 (cast
                  (cond
                   (voidstar
                    (mixed-append "(" c-attr-type "*)"))
                   (pointer
                    (mixed-append "(" c-attr-type ")"))
                                        ; XXX: cast primitive types too, should help with enums in C++
                   (else "")))
                 (dereference (if voidstar "*" "")))
             `(##define ,(symbol-append
                          scheme-type "-" scheme-attr-name "-set!")
                (c-lambda
                 (,scheme-type ,scheme-attr-type) void
                 ,(string-append
                   "(*(" c-type-name "*)___arg1_voidstar)." c-attr-name
                   " = " dereference cast "___arg2" _voidstar ";"))))))))
    (append
     `(begin
        (c-define-type ,scheme-type (,struct-or-union ,c-type-name ,c-type))
                                        ; Unmanaged version of structure.
        (c-define-type ,(symbol-append unmanaged-prefix scheme-type)
                       (,struct-or-union ,c-type-name ,c-type "ffimacro__leave_alone"))
        (c-define-type
         ,pointer-type
         (pointer ,scheme-type ,pointer-type))
        (c-define-type
         ,(symbol-append managed-prefix pointer-type)
         (pointer ,scheme-type ,pointer-type "ffimacro__free_foreign"))
        (##define ,(symbol-append "make-" scheme-type)
                                        ; Constructor.
          (c-lambda
           () ,scheme-type
           ,(string-append "___result_voidstar = malloc(sizeof(" c-type-name "));")))
        (##define (,(symbol-append scheme-type "?") x)
                                        ; Type predicate.
          (and (foreign? x) (memq (quote ,c-type) (foreign-tags x)) #t))
        (##define (,(symbol-append scheme-type "-pointer?") x)
                                        ; Pointer type predicate.
          (and (foreign? x)
               (memq (quote ,pointer-type)
                     (foreign-tags x))
               #t))
        (##define (,(symbol-append scheme-type "-pointer") x)
                                        ; Take pointer.
          (let ((ret
                 ((c-lambda
                   (,scheme-type) ,pointer-type
                   "___result_voidstar = ___arg1_voidstar;")
                  x)))
            (ffi:link x ret)
            ret))
        (##define (,(symbol-append "pointer->" scheme-type) x)
                                        ; Pointer dereference
          (let ((ret
                 ((c-lambda
                   (,pointer-type) ,(symbol-append unmanaged-prefix scheme-type)
                   "___result_voidstar = ___arg1_voidstar;")
                  x)))
            (ffi:link x ret)
            ret))
        (##define ,(symbol-append "make-" scheme-type "-array")
          (c-lambda
           (int) ,(symbol-append managed-prefix pointer-type)
           ,(string-append
             "___result_voidstar = malloc(___arg1 * sizeof(" c-type-name "));")))
        (##define (,(symbol-append scheme-type "-pointer-offset") p i)
          (let ((ret
                 ((c-lambda
                   (,pointer-type int) ,pointer-type
                   ,(string-append "___result_voidstar = (" c-type-name "*)___arg1_voidstar + ___arg2;"))
                  p i)))
            (ffi:link p ret)
            ret)))
     (map accessor fields)
     (map mutator fields))))

(##define-macro
  (c-struct . type.fields)
  (c-native 'struct (car type.fields) (cdr type.fields)))

(##define-macro
  (c-union . type.fields)
  (c-native 'union (car type.fields) (cdr type.fields)))

;;; Build a size-of value equivalent to the C operator
;;; c-build-sizeof float -> sizeof-float

(##define-macro c-build-sizeof
  (lambda (type)
    (let ((type-str (symbol->string type)))
      `(##define ,(string->symbol (string-append "sizeof-" type-str))
         ((c-lambda () unsigned-int
                    ,(string-append "___result = sizeof(" type-str ");")))))))

;;; Automatic memory freeing macro

;; (##define-macro (with-alloc ?b ?e . ?rest)
;;   `(let ((,?b ,?e))
;;      (let ((ret (begin ,@?rest)))
;;        (free ,(car expr))
;;        ret)))

(c-define-type void* (pointer void))
(c-define-type bool* (pointer bool))
(c-define-type short* (pointer short))
(c-define-type unsigned-short* (pointer unsigned-short))
(c-define-type int* (pointer int))
(c-define-type unsigned-int* (pointer unsigned-int))
(c-define-type long* (pointer long))
(c-define-type unsigned-long* (pointer unsigned-long))
(c-define-type long-long* (pointer long-long))
(c-define-type unsigned-long-long* (pointer unsigned-long-long))
(c-define-type float* (pointer float))
(c-define-type double* (pointer double))
(c-define-type unsigned-char* (pointer unsigned-char))
(c-define-type unsigned-char** (pointer unsigned-char*))
(c-define-type int8* (pointer int8))
(c-define-type unsigned-int8* (pointer unsigned-int8))
(c-define-type int16* (pointer int16))
(c-define-type unsigned-int16* (pointer unsigned-int16))
(c-define-type int32* (pointer int32))
(c-define-type unsigned-int32* (pointer unsigned-int32))
(c-define-type int64* (pointer int64))
(c-define-type unsigned-int64* (pointer unsigned-int64))

(c-define-type size-t unsigned-int)
(else)

(cond-expand
 (compile-to-o
  (c-declare #<<c-declare-end

#ifndef FFIMACRO
#define FFIMACRO

#include <malloc.h>

___SCMOBJ ffimacro__leave_alone(void *p)
{
  return ___FIX(___NO_ERR);
}

___SCMOBJ ffimacro__free_foreign(void *p)
{
  if (p)
    free(p);
  return ___FIX(___NO_ERR);
}

#endif

c-declare-end
             ))
 (compile-to-c
  (c-declare #<<c-declare-end

             ___SCMOBJ ffimacro__leave_alone(void *p);
             ___SCMOBJ ffimacro__free_foreign(void *p);

c-declare-end
             ))
 (else))

;-------------------------------------------------------------------------------
; Objective-C utilities
;-------------------------------------------------------------------------------

;; Code by Jeffrey T. Read
;; The API is as follows:
;;
;; (objc-method class-name (formaltype1 ...) return-type method-name)
;;
;;   Creates a `c-lambda' that wraps an invocation of method
;;   `method-name' to objects of class `class-name'. So for example if
;;   you had:
;;
;;   @class Barney;
;;   @interface Fred
;;   { ... }
;;   -(int)frobWithBarney: (Barney *)aBarney wearFunnyHats: (BOOL) hats;
;;   +instanceNumber: (int) n
;;   @end
;;
;;   you could wrap the frobWithBarney method with something like the
;;   following:
;;
;;   (define frob-with-barney
;;    (objc-method "Fred" ((pointer "Barney") bool) int
;;                 "frobWithBarney:wearFunnyHats:"))
;;
;;   Then if Scheme-side you had a pointer to Fred `f' and a pointer
;;   to Barney `b' you could call from Scheme:
;;
;;   (frob-with-barney f b #t)
;;
;;   Procedures which wrap Objective-C methods in this way take one
;;   additional argument to the ones accounted for in their formals
;;   list. Their first argument should be a pointer to the object on
;;   which the method is invoked, followed by the arguments in the
;;   formals list, as in the example above which takes a pointer to
;;   Fred, a pointer to Barney, and a boolean value.
;;
;; (objc-class-method class-name (formaltype1 ...) return-type method-name)
;;
;;   Creates a `c-lambda' that wraps an invocation of class method
;;   `method-name' in class `class-name'. For instance, in class Fred
;;   above you could wrap the class method instanceNumber with the following:
;;
;;   (define fred-instance-number
;;    (objc-class-method "Fred" (int) (pointer Fred) "instanceNumber:"))
;;
;;   Then Scheme-side you could get a pointer to Fred with a call like:
;;
;;   (fred-instance-number 5)
;;
;;   Procedures which wrap Objective-C class methods in this way take
;;   only the arguments accounted for in their formals list.


;; (##define-macro (ffi:objc-method class-name class? formal-types return-type method-name)
;;   (define (parse-method-name m)
;;     (define (split-at-colon s)
;;       (let ((l (string-length s)))
;; 	(call-with-current-continuation
;; 	 (lambda (k)
;; 	   (do ((i 0 (+ i 1)))
;; 	       ((>= i l) #f)
;; 	     (if (char=? (string-ref s i) #\:)
;; 		 (k (cons (substring s 0 (+ i 1))
;; 			  (substring s (+ i 1) l)))))))))
;;     (define (parse-method-name1 m acc)
;;       (let ((p (split-at-colon m)))
;; 	(if (not p)
;; 	    (if (null? acc) (cons m acc) acc)
;; 	    (parse-method-name1 (cdr p) (cons (car p) acc)))))
;;     (reverse (parse-method-name1 m '())))
;;   (define (make-methodcall lst start)
;;     (if (and (= (length lst) 1)
;; 	     (not (char=? (string-ref 
;; 			   (car lst)
;; 			   (- (string-length (car lst)) 1))
;; 			  #\:)))
;; 	(car lst)
;; 	(do ((i start (+ i 1))
;; 	     (l lst (cdr l))
;; 	     (s ""
;; 		(string-append s
;; 			       (car l)
;; 			       " ___arg"
;; 			       (number->string i)
;; 			       " ")))
;; 	    ((null? l) s))))
;;   (let* ((res (cond
;; 	       ((list? return-type)
;; 		"___result_voidstar = (void *)")
;; 	       ((eq? return-type 'void) "")
;; 	       (else "___result = ")))
;; 	 (methodparts (parse-method-name method-name)))
;;     `(c-lambda ,(if class? formal-types (cons (list 'pointer class-name) formal-types)) ,return-type
;;                ,(string-append
;;                  (if class?
;;                      (string-append res "[" class-name " ")
;;                      (string-append res "[___arg1 "))
;;                  (make-methodcall methodparts (if class? 1 2))
;;                  "];"))))

;; (##define-macro (ffi:objc-method class-name formal-types return-type method-name)
;;   `(%%objc-method ,class-name #f ,formal-types ,return-type ,method-name))

;; (##define-macro (ffi:objc-class-method class-name formal-types return-type method-name)
;;   `(%%objc-method ,class-name #t ,formal-types ,return-type ,method-name))
