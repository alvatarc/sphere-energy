(sphere: "energy")
(dependencies:
 (exception
  (load (fabric: algorithm/list)))
 (functional-arguments
  (include (core: base-macros)))
 (rest-values
  (load (fabric: algorithm/list)))
 (testing-macros
  (include (= exception-macros)))
 (testing
  (load (energy: exception))))
