;; Second Clojure sample: a ring-style handler, transducers, core.async-ish code,
;; and an unterminated string followed by an unterminated form at EOF.

(ns stress.server
  (:require [clojure.edn :as edn]
            [clojure.string :as str]
            [clojure.walk :refer [keywordize-keys]])
  (:gen-class))

(def ^:const default-port 8080)
(def ^:private routes-table (atom {}))

(defmacro defroute
  "Registers a route. Usage: (defroute :get \"/path\" [req] body)"
  [method path args & body]
  `(swap! routes-table assoc [~method ~path] (fn ~args ~@body)))

(defn- parse-query [^String qs]
  (when-not (str/blank? qs)
    (->> (str/split qs #"&")
         (map #(str/split % #"=" 2))
         (into {} (map (fn [[k v]] [(keyword k) (or v "")]))))))

(defn- json-escape [s]
  (str/escape (str s) {\" "\\\"" \\ "\\\\" \newline "\\n" \tab "\\t"}))

(defn- ->json [m]
  (str "{"
       (str/join ","
                 (for [[k v] m]
                   (str "\"" (name k) "\":"
                        (cond
                          (string? v) (str "\"" (json-escape v) "\"")
                          (nil? v) "null"
                          :else (str v)))))
       "}"))

(defn response
  ([body] (response 200 body))
  ([status body]
   {:status status
    :headers {"Content-Type" "application/json; charset=utf-8"
              "X-Powered-By" "clojure"}
    :body (if (map? body) (->json body) (str body))}))

(defroute :get "/health" [_]
  (response {:status "ok" :uptime-ms (System/currentTimeMillis)}))

(defroute :get "/echo" [{:keys [query-string]}]
  (response (parse-query query-string)))

(defroute :post "/config" [{:keys [body]}]
  (try
    (let [cfg (edn/read-string {:readers {'env #(System/getenv (str %))}} body)]
      (response {:accepted (count cfg)}))
    (catch Exception e
      (response 400 {:error (.getMessage e)}))))

(defn handler [{:keys [request-method uri] :as req}]
  (if-let [f (get @routes-table [request-method uri])]
    (f req)
    (response 404 {:error (format "no route for %s %s" (name request-method) uri)})))

(defn wrap-logging [h]
  (fn [req]
    (let [start (System/nanoTime)
          resp (h req)
          ms (/ (- (System/nanoTime) start) 1e6)]
      (println (format "%s %s -> %d (%.2fms)"
                       (str/upper-case (name (:request-method req)))
                       (:uri req)
                       (:status resp)
                       ms))
      resp)))

;; Transducers
(def xf
  (comp (map inc)
        (filter odd?)
        (partition-all 3)
        (map (partial apply +))))

(transduce xf + (range 100))
(into [] xf (range 20))
(sequence (comp (dedupe) (take 5)) [1 1 2 2 3 3 4 5 6])

;; EDN-like data with every literal type
(def sample-edn
  "{:string \"value with \\\"quotes\\\"\"
    :char \\c
    :num 1.5M
    :ratio 3/4
    :regex-like \"#\\\"not a regex\\\"\"
    :set #{1 2}
    :tagged #inst \"2024-01-01\"}")

(def parsed (edn/read-string sample-edn))

;; Destructuring galore
(let [{:keys [a b] :or {a 1} :as m} {:b 2}
      {{:keys [deep]} :nested} {:nested {:deep :value}}
      [x & {:keys [opt]}] [1 :opt true]
      {:strs [s1 s2]} {"s1" 1 "s2" 2}
      {:syms [sym]} {'sym 3}
      ^long n 10]
  [a b m deep x opt s1 s2 sym n])

;; Reader edge cases at line boundaries
(def edge-1 #{
  :set-opened-on-previous-line})
(def edge-2 #"regex that \
continues?")
(def edge-3 ^{:meta
              :spanning-lines} [])
(def edge-4 '(quoted
              list))
(def edge-5 `(syntax ~quoted
              ~@spliced))
(def edge-6 #_
  :discarded-on-next-line)
(def edge-7 \;)  ; a semicolon character, not a comment start
(def edge-8 [\[ \] \( \) \{ \}])
(def edge-9 :a/b/c)
(def edge-10 'ns.sub/sym-name)

(defn -main [& args]
  (let [port (or (some-> (first args) parse-long) default-port)
        app (wrap-logging handler)]
    (println (str "Listening on port " port " — try /health or /echo?a=1&b=2"))
    (doseq [req [{:request-method :get :uri "/health"}
                 {:request-method :get :uri "/echo" :query-string "x=1&y=two"}
                 {:request-method :post :uri "/config" :body "{:a 1 :b #env \"HOME\"}"}
                 {:request-method :delete :uri "/nope"}]]
      (println (:body (app req))))))

;; Protocol extension and reify
(defprotocol Renderable
  (render [this] "Render to a string")
  (render-with [this opts]))

(extend-protocol Renderable
  String
  (render [s] (str "\"" (json-escape s) "\""))
  (render-with [s {:keys [quote?] :or {quote? true}}] (if quote? (render s) s))
  Number
  (render [n] (str n))
  (render-with [n _] (str n))
  nil
  (render [_] "null")
  (render-with [_ _] "null"))

(def anonymous-renderer
  (reify Renderable
    (render [_] "#reified")
    (render-with [_ opts] (str "#reified " (pr-str opts)))))

(letfn [(even?* [n] (if (zero? n) true (odd?* (dec n))))
        (odd?* [n] (if (zero? n) false (even?* (dec n))))]
  (even?* 10))

;; The final form opens a string that never closes:
(def unterminated-doc "This string runs to the end of the file.
It contains (parens) and [brackets] and {braces} and ; semicolons
and \"escaped quotes\" but never an unescaped closing quote.
(defn not-code [] :still-string)
