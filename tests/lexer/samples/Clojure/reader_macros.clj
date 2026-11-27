;; Clojure lexer stress: reader macros, sets, regex, keywords, metadata, discard
;;; Triple-semicolon comment
;;;; Section header comment

(ns stress.reader-macros
  "Namespace docstring with \"escaped quotes\" and ; semicolons"
  (:require [clojure.string :as str]
            [clojure.set :refer [union intersection]]
            [clojure.java.io :as io])
  (:import (java.util Date UUID)
           [java.time Instant Duration]))

(set! *warn-on-reflection* true)

;; Strings
(def s1 "double \"quoted\" with \\ and \n and \t and A and \101")
(def s2 "multi-line
string spanning
three lines")
(def s3 "semicolon ; not a comment and #{not a set}")
(def s4 "trailing backslash \\")
(def s5 "unterminated on this line
(def s6 "after")

;; Characters
(def chars [\a \A \space \newline \tab \return \backspace \formfeed
            A \o101 \\ \" \( \) \; \# \' \` \~ \@ \^ \{ \}])
(def tricky-char-list [\a\b\c])

;; Numbers
(def numbers [42 -42 +42 42N 0x2A 0X2a 052 2r101010 8r52 16rFF 36rZZ
              1.5 -1.5 1.5e10 1.5E-3 1.5M 1/3 -22/7 ##Inf ##-Inf ##NaN])

;; Keywords and symbols
(def kws [:simple :ns/qualified ::auto-resolved ::str/aliased :a.b/c :with-dash? :bang!
          :1 :+ :- :* :/ :< :> :=])
(def syms '[a b.c d/e +foo+ *earmuffs* ->arrow <-back a? b! a' a'b ._ .method Class.])
(def special 'quote)

;; Collections
(def v [1 2 [3 [4 [5]]]])
(def m {:a 1, "b" 2, 3 :c, [1 2] #{:set-key}})
(def s #{1 2 3 #{:nested}})
(def l '(1 2 3))
(def nsmap #:person{:name "Ada" :age 36})
(def nsmap-auto #::{:x 1})

;; Regex literals
(def re1 #"\d+\.\d+")
(def re2 #"[a-z]+\s*\"quoted\"")
(def re3 #"(?i)case insensitive; not a comment")
(def re4 #"escaped \\ backslash and \/ slash")

;; Anonymous function literals
(def f1 #(* % 2))
(def f2 #(+ %1 %2 %3))
(def f3 #(apply str %&))
(def f4 #(vector % (inc %)))

;; Metadata
(def ^:private secret 42)
(def ^{:doc "documented" :added "1.0"} documented :value)
(defn ^String typed-fn [^long x ^"[Ljava.lang.String;" arr] (str x))
(def ^:dynamic *dyn* nil)
(def with-meta-obj (with-meta [1 2] {:source :test}))

;; Discard
(def discarded [1 #_2 3 #_(this whole form is discarded) 4 #_#_5 6 7])
#_(defn completely-ignored []
    "this function is discarded by the reader")

;; Comment form
(comment
  (println "this is code inside comment, still read")
  (+ 1 2)
  :keyword-in-comment)

;; Syntax quote, unquote, unquote-splicing
(defmacro unless [test & body]
  `(if (not ~test)
     (do ~@body)
     nil))

(defmacro with-gensym [& body]
  (let [x# (gensym)]
    `(let [result# (do ~@body)]
       result#)))

;; Deref, var quote
(def a (atom 0))
(swap! a inc)
(println @a)
(def v-ref #'secret)
(def deref-form (deref a))

;; Reader conditionals
(def platform
  #?(:clj "JVM"
     :cljs "JavaScript"
     :default "unknown"))
(def spliced [1 #?@(:clj [2 3] :cljs [4 5]) 6])

;; Tagged literals
(def inst #inst "2024-01-01T00:00:00.000-00:00")
(def uuid #uuid "00000000-0000-0000-0000-000000000000")
(def custom #my/tag {:data 1})

;; Functions
(defn greet
  "Greets a person with \"style\"."
  ([] (greet "World"))
  ([name] (greet name "!"))
  ([name punct & {:keys [loud?] :or {loud? false}}]
   (let [msg (str "Hello, " name punct)]
     (if loud? (str/upper-case msg) msg))))

(defn- private-fn [{:keys [a b] :as all} [x y & rest]]
  {:pre [(pos? a)] :post [(map? %)]}
  {:sum (+ a b x y) :rest rest :all all})

(defmulti area :shape)
(defmethod area :circle [{:keys [r]}] (* Math/PI r r))
(defmethod area :rect [{:keys [w h]}] (* w h))
(defmethod area :default [_] 0)

(defprotocol Shape
  (perimeter [this] "Returns the perimeter"))

(defrecord Circle [r]
  Shape
  (perimeter [_] (* 2 Math/PI r)))

(deftype Point [x y]
  Object
  (toString [_] (str "Point(" x ", " y ")")))

;; Threading macros
(->> (range 10)
     (filter even?)
     (map #(* % %))
     (reduce +))
(-> {:a 1}
    (assoc :b 2)
    (update :a inc))
(some-> nil :a :b)
(cond-> 1 true inc false dec)
(as-> 1 $ (+ $ 1) (* $ 2))

;; Java interop
(.toUpperCase "abc")
(Math/abs -1)
(new Date)
(Date.)
(.. System (getProperties) (get "os.name"))
(doto (java.util.ArrayList.) (.add 1) (.add 2))

;; Loops
(loop [i 0 acc []]
  (if (< i 5)
    (recur (inc i) (conj acc i))
    acc))

(doseq [x [1 2 3] :let [y (* x x)] :when (odd? y)]
  (println x y))

(for [x (range 3) y (range 3) :while (< y x)] [x y])

(try
  (throw (ex-info "boom" {:code 42}))
  (catch clojure.lang.ExceptionInfo e (ex-data e))
  (catch Exception e (.getMessage e))
  (finally (println "done")))
