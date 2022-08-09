---- MODULE cache ----
EXTENDS TLC, Integers, Sequences, FiniteSets

CONSTANT 
    NULL,
    MaxSeries,
    MaxEpochs,
    Delay,
    Ingesters,
    BgWorkers,
    CacheRefreshWorkers
ASSUME 
    /\ MaxSeries \in Nat 
    /\ MaxEpochs \in Nat
    /\ Delay \in 0..(MaxEpochs - 1)
    /\ Cardinality(BgWorkers) > 0
    /\ Cardinality(Ingesters) > 0
    /\ Cardinality(CacheRefreshWorkers) = 1
    /\ BgWorkers \intersect Ingesters = {}
    /\ BgWorkers \intersect CacheRefreshWorkers = {}

SeriesId == 1..MaxSeries
Epoch == 0..MaxEpochs
SeriesEntry ==
    [
        marked_at: Epoch \union {NULL},
        stored: BOOLEAN \* In TLA function sets are total, therefore we need an explicit flag
    ]
NoEntry == [marked_at |-> NULL, stored |-> FALSE]
NewEntry == [marked_at |-> NULL, stored |-> TRUE]
EntryMarkedForDeletion(e) == [marked_at |-> e, stored |-> TRUE]

Max(S) == CHOOSE x \in S : \A y \in S : x >= y
Min(S) == CHOOSE x \in S : \A y \in S : x =< y

(*--algorithm cache
variables
    now = 1;
    current_epoch = 0;
    delete_epoch = 0;
    series_metadata = [x \in SeriesId |-> NoEntry];
    series_referenced_from_data = {};
    cached_series = [i \in Ingesters |-> {}];
    observed_epochs = [i \in Ingesters |-> 0];

define
    TypeInvariant == 
        /\ now \in Epoch
        /\ current_epoch \in Epoch
        /\ delete_epoch \in Epoch
        /\ series_metadata \in [SeriesId -> SeriesEntry]
        /\ series_referenced_from_data \in SUBSET SeriesId
        /\ cached_series \in [Ingesters -> SUBSET SeriesId]
        /\ observed_epochs \in [Ingesters -> Epoch]

    ForeignKeySafety ==
        /\ \A sid \in series_referenced_from_data: series_metadata[sid].stored = TRUE

    StoredSeries == 
        {s \in DOMAIN series_metadata: series_metadata[s].stored = TRUE}

    MarkedSeries == 
        {s \in DOMAIN series_metadata: series_metadata[s].marked_at # NULL}

    MarkedAndRipe(e) == 
        {s \in MarkedSeries: (series_metadata[s].marked_at) < e }

    NewDataAfterMarked ==
        {s \in MarkedSeries: s \in series_referenced_from_data}

end define;

process cache_refresh_worker \in CacheRefreshWorkers
variables 
    fetched_cur_epoch = 0;
    fetched_del_epoch = 0;
    fetched_series = {};
begin
    (* 
     * Under Read Commited each statement might see slightly different state.
     * It is modelled by confining each statement to its own label/action.
     *)
    SelectEpoch:
        (* 
         * Should use SELECT FOR SHARE when fetching epochs,
         * to observe them at the exact same moment.
         *)
        fetched_cur_epoch := current_epoch;
        fetched_del_epoch := delete_epoch;
    SelectMarked:
        (* SELECT id FROM _prom_catalog.series WHERE delete_at IS NOT NULL *)
        fetched_series := MarkedSeries;
    ScrubCache:
        (* This needs to be under an RW mutex *)
        with i \in Ingesters do 
            if observed_epochs[i] <= fetched_del_epoch then
                (* 
                 * Observed epoch is too far behind: some items in 
                 * the cache may already have been deleted in the 
                 * database without giving this cache a chance to
                 * observe their "marked" state.
                 *)
                cached_series[i] := {};
            else
                cached_series[i] := cached_series[i] \ fetched_series;
            end if;
            observed_epochs[i] := fetched_cur_epoch;
        end with;
end process;

process ingester \in Ingesters
variables 
    new_series = {};
    new_references = {};
    locally_observed_epoch = 0;
begin
    IngesterBegin:
        either
            ReceiveInput:
                (*
                 * Technically multiple series could be ingested at once.
                 * This spec should achieve an equivalent behaviour by
                 * passing through IngesterBegin multiple times in a row.
                 *)
                with series \in SeriesId do 
                    new_series := { series };
                end with;
            CacheLookupTransaction:
                (* The cache RW mutex must be held during this transaction *)
                new_references := new_series;
                new_series := new_series \ cached_series[self];
                (* 
                 * get_or_create_series_id calls ressurect_series_id 
                 * which, in turn, uses UPDATE and will cause a transaction
                 * conflict with a simultaneous deletion attempt.
                 *)
                series_metadata := [x \in new_series |-> NewEntry] @@ series_metadata;
                (*
                 * The previous line is actually a DB transaction that could
                 * be rolled back. We don't hadle it here for the sake of not
                 * bloating this spec even more. It shuold be entirely safe to
                 * wipe the cache clean if a rollback happens.
                 *)
                cached_series[self] := cached_series[self] \union new_series;
                locally_observed_epoch := observed_epochs[self];
            IngestTransaction:
                (* this if is epoch_abort *)
                if locally_observed_epoch <= delete_epoch then 
                    skip;
                else
                    series_referenced_from_data := series_referenced_from_data \union new_references;
                end if;
                goto IngesterBegin;
        or
            (* Ingester is done *)
            skip;
        end either;
end process;        

process bg_worker \in BgWorkers
variables
    candidates = {};
    (* 
     * Could be either current or delete epoch, depending on the branch.
     * Used only as a local cache and re-initializaed on every iteration.
     *)
    locally_observed_epoch = 0; 
begin
    (* 
     * Under Read Commited each statement might see slightly different state.
     * It is modelled by confining each statement to its own label/action.
     *)
    BgWorkerTxBegin:
        while now < MaxEpochs do
            (* When a backgroud worker starts a transaction, sometimes some time has passed. *)
            with dt \in 0..1 do
                now := now + dt;
            end with;
            (* 
             * In fact, drop_metric_chunks goes through these stages sequentially. So, this actually
             * adds a touch more concurrency. But we assume concurrent phases mutually exclude
             * by grabbing a lock.
             *)
            either
                (* drop_metric_chunk_data *)
                DropChunkData:
                    (*
                     * Technically multiple series could be dropped at once.
                     * This spec is supposed to achieve this by entering 
                     * this branch of either without advancing now.
                     *)
                    with series_to_drop \in SeriesId do 
                        series_referenced_from_data := series_referenced_from_data \ {series_to_drop};
                    end with;
            or
                (* mark_series_to_be_dropped_as_unused *)
                MarkUnused:
                    (* SELECT FOR SHARE current_epoch FROM epoch_table *)
                    locally_observed_epoch := Max({current_epoch, now});
                    with 
                        stale_series = {s \in StoredSeries: 
                                        /\ (s \notin series_referenced_from_data) 
                                        (* Filtering out MarkedSeries is not mandatory, 
                                         * but by re-marking everything every time we may hide
                                         * design errors in other parts of the system.
                                         *)
                                        /\ (s \notin MarkedSeries) 
                                        } 
                    do 
                        series_metadata := 
                            [s \in stale_series |-> EntryMarkedForDeletion(locally_observed_epoch)] @@ series_metadata;
                    end with;
                AdvanceEpoch:
                    (* 
                     * This must happen AFTER marking. 
                     * Cache scrubber reads in the oppposite order, first current_epoch, then rows
                     * It guarantees that it sees marked rows of _at least_ current_epoch (or newer)
                     *)
                    current_epoch := Max({current_epoch, locally_observed_epoch});
            or
                (* delete_expired_series *)
                PrepareDeleteTx:
                    (* This requires an UPDATE lock on delete_epoch, and current_epoch *)
                    delete_epoch := Max({current_epoch - Delay, delete_epoch});
                    locally_observed_epoch := delete_epoch;
                    (* First COMMIT *)
                ActuallyDeleteTx:
                    (*
                     * DELETE ... RETURNING id statment. Otherwise
                     * under Read Commited it could stomp over a client-driven
                     * ressurect-UPDATE.
                     * (Alternatively, rechecking WHERE conditions should work)
                     *
                     * DELETE should provoke a conflict with
                     * get_or_create_series_id called by Ingester
                     *)
                    candidates := MarkedAndRipe(locally_observed_epoch) \ NewDataAfterMarked; 
                    series_metadata := [x \in candidates |-> NoEntry] @@ series_metadata;
                Ressurect:
                    series_metadata := 
                        [x \in (MarkedAndRipe(locally_observed_epoch) \ candidates) |-> NewEntry] @@ series_metadata;
                    (* Second COMMIT *)
            end either;
        end while;
end process;        
end algorithm; *)
    
\* BEGIN TRANSLATION (chksum(pcal) = "b930fce0" /\ chksum(tla) = "a88ad055")
\* Process variable locally_observed_epoch of process ingester at line 115 col 5 changed to locally_observed_epoch_
VARIABLES now, current_epoch, delete_epoch, series_metadata, 
          series_referenced_from_data, cached_series, observed_epochs, pc

(* define statement *)
TypeInvariant ==
    /\ now \in Epoch
    /\ current_epoch \in Epoch
    /\ delete_epoch \in Epoch
    /\ series_metadata \in [SeriesId -> SeriesEntry]
    /\ series_referenced_from_data \in SUBSET SeriesId
    /\ cached_series \in [Ingesters -> SUBSET SeriesId]
    /\ observed_epochs \in [Ingesters -> Epoch]

ForeignKeySafety ==
    /\ \A sid \in series_referenced_from_data: series_metadata[sid].stored = TRUE

StoredSeries ==
    {s \in DOMAIN series_metadata: series_metadata[s].stored = TRUE}

MarkedSeries ==
    {s \in DOMAIN series_metadata: series_metadata[s].marked_at # NULL}

MarkedAndRipe(e) ==
    {s \in MarkedSeries: (series_metadata[s].marked_at) < e }

NewDataAfterMarked ==
    {s \in MarkedSeries: s \in series_referenced_from_data}

VARIABLES fetched_cur_epoch, fetched_del_epoch, fetched_series, new_series, 
          new_references, locally_observed_epoch_, candidates, 
          locally_observed_epoch

vars == << now, current_epoch, delete_epoch, series_metadata, 
           series_referenced_from_data, cached_series, observed_epochs, pc, 
           fetched_cur_epoch, fetched_del_epoch, fetched_series, new_series, 
           new_references, locally_observed_epoch_, candidates, 
           locally_observed_epoch >>

ProcSet == (CacheRefreshWorkers) \cup (Ingesters) \cup (BgWorkers)

Init == (* Global variables *)
        /\ now = 1
        /\ current_epoch = 0
        /\ delete_epoch = 0
        /\ series_metadata = [x \in SeriesId |-> NoEntry]
        /\ series_referenced_from_data = {}
        /\ cached_series = [i \in Ingesters |-> {}]
        /\ observed_epochs = [i \in Ingesters |-> 0]
        (* Process cache_refresh_worker *)
        /\ fetched_cur_epoch = [self \in CacheRefreshWorkers |-> 0]
        /\ fetched_del_epoch = [self \in CacheRefreshWorkers |-> 0]
        /\ fetched_series = [self \in CacheRefreshWorkers |-> {}]
        (* Process ingester *)
        /\ new_series = [self \in Ingesters |-> {}]
        /\ new_references = [self \in Ingesters |-> {}]
        /\ locally_observed_epoch_ = [self \in Ingesters |-> 0]
        (* Process bg_worker *)
        /\ candidates = [self \in BgWorkers |-> {}]
        /\ locally_observed_epoch = [self \in BgWorkers |-> 0]
        /\ pc = [self \in ProcSet |-> CASE self \in CacheRefreshWorkers -> "SelectEpoch"
                                        [] self \in Ingesters -> "IngesterBegin"
                                        [] self \in BgWorkers -> "BgWorkerTxBegin"]

SelectEpoch(self) == /\ pc[self] = "SelectEpoch"
                     /\ fetched_cur_epoch' = [fetched_cur_epoch EXCEPT ![self] = current_epoch]
                     /\ fetched_del_epoch' = [fetched_del_epoch EXCEPT ![self] = delete_epoch]
                     /\ pc' = [pc EXCEPT ![self] = "SelectMarked"]
                     /\ UNCHANGED << now, current_epoch, delete_epoch, 
                                     series_metadata, 
                                     series_referenced_from_data, 
                                     cached_series, observed_epochs, 
                                     fetched_series, new_series, 
                                     new_references, locally_observed_epoch_, 
                                     candidates, locally_observed_epoch >>

SelectMarked(self) == /\ pc[self] = "SelectMarked"
                      /\ fetched_series' = [fetched_series EXCEPT ![self] = MarkedSeries]
                      /\ pc' = [pc EXCEPT ![self] = "ScrubCache"]
                      /\ UNCHANGED << now, current_epoch, delete_epoch, 
                                      series_metadata, 
                                      series_referenced_from_data, 
                                      cached_series, observed_epochs, 
                                      fetched_cur_epoch, fetched_del_epoch, 
                                      new_series, new_references, 
                                      locally_observed_epoch_, candidates, 
                                      locally_observed_epoch >>

ScrubCache(self) == /\ pc[self] = "ScrubCache"
                    /\ \E i \in Ingesters:
                         /\ IF observed_epochs[i] <= fetched_del_epoch[self]
                               THEN /\ cached_series' = [cached_series EXCEPT ![i] = {}]
                               ELSE /\ cached_series' = [cached_series EXCEPT ![i] = cached_series[i] \ fetched_series[self]]
                         /\ observed_epochs' = [observed_epochs EXCEPT ![i] = fetched_cur_epoch[self]]
                    /\ pc' = [pc EXCEPT ![self] = "Done"]
                    /\ UNCHANGED << now, current_epoch, delete_epoch, 
                                    series_metadata, 
                                    series_referenced_from_data, 
                                    fetched_cur_epoch, fetched_del_epoch, 
                                    fetched_series, new_series, new_references, 
                                    locally_observed_epoch_, candidates, 
                                    locally_observed_epoch >>

cache_refresh_worker(self) == SelectEpoch(self) \/ SelectMarked(self)
                                 \/ ScrubCache(self)

IngesterBegin(self) == /\ pc[self] = "IngesterBegin"
                       /\ \/ /\ pc' = [pc EXCEPT ![self] = "ReceiveInput"]
                          \/ /\ TRUE
                             /\ pc' = [pc EXCEPT ![self] = "Done"]
                       /\ UNCHANGED << now, current_epoch, delete_epoch, 
                                       series_metadata, 
                                       series_referenced_from_data, 
                                       cached_series, observed_epochs, 
                                       fetched_cur_epoch, fetched_del_epoch, 
                                       fetched_series, new_series, 
                                       new_references, locally_observed_epoch_, 
                                       candidates, locally_observed_epoch >>

ReceiveInput(self) == /\ pc[self] = "ReceiveInput"
                      /\ \E series \in SeriesId:
                           new_series' = [new_series EXCEPT ![self] = { series }]
                      /\ pc' = [pc EXCEPT ![self] = "CacheLookupTransaction"]
                      /\ UNCHANGED << now, current_epoch, delete_epoch, 
                                      series_metadata, 
                                      series_referenced_from_data, 
                                      cached_series, observed_epochs, 
                                      fetched_cur_epoch, fetched_del_epoch, 
                                      fetched_series, new_references, 
                                      locally_observed_epoch_, candidates, 
                                      locally_observed_epoch >>

CacheLookupTransaction(self) == /\ pc[self] = "CacheLookupTransaction"
                                /\ new_references' = [new_references EXCEPT ![self] = new_series[self]]
                                /\ new_series' = [new_series EXCEPT ![self] = new_series[self] \ cached_series[self]]
                                /\ series_metadata' = [x \in new_series'[self] |-> NewEntry] @@ series_metadata
                                /\ cached_series' = [cached_series EXCEPT ![self] = cached_series[self] \union new_series'[self]]
                                /\ locally_observed_epoch_' = [locally_observed_epoch_ EXCEPT ![self] = observed_epochs[self]]
                                /\ pc' = [pc EXCEPT ![self] = "IngestTransaction"]
                                /\ UNCHANGED << now, current_epoch, 
                                                delete_epoch, 
                                                series_referenced_from_data, 
                                                observed_epochs, 
                                                fetched_cur_epoch, 
                                                fetched_del_epoch, 
                                                fetched_series, candidates, 
                                                locally_observed_epoch >>

IngestTransaction(self) == /\ pc[self] = "IngestTransaction"
                           /\ IF locally_observed_epoch_[self] <= delete_epoch
                                 THEN /\ TRUE
                                      /\ UNCHANGED series_referenced_from_data
                                 ELSE /\ series_referenced_from_data' = (series_referenced_from_data \union new_references[self])
                           /\ pc' = [pc EXCEPT ![self] = "IngesterBegin"]
                           /\ UNCHANGED << now, current_epoch, delete_epoch, 
                                           series_metadata, cached_series, 
                                           observed_epochs, fetched_cur_epoch, 
                                           fetched_del_epoch, fetched_series, 
                                           new_series, new_references, 
                                           locally_observed_epoch_, candidates, 
                                           locally_observed_epoch >>

ingester(self) == IngesterBegin(self) \/ ReceiveInput(self)
                     \/ CacheLookupTransaction(self)
                     \/ IngestTransaction(self)

BgWorkerTxBegin(self) == /\ pc[self] = "BgWorkerTxBegin"
                         /\ IF now < MaxEpochs
                               THEN /\ \E dt \in 0..1:
                                         now' = now + dt
                                    /\ \/ /\ pc' = [pc EXCEPT ![self] = "DropChunkData"]
                                       \/ /\ pc' = [pc EXCEPT ![self] = "MarkUnused"]
                                       \/ /\ pc' = [pc EXCEPT ![self] = "PrepareDeleteTx"]
                               ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                                    /\ now' = now
                         /\ UNCHANGED << current_epoch, delete_epoch, 
                                         series_metadata, 
                                         series_referenced_from_data, 
                                         cached_series, observed_epochs, 
                                         fetched_cur_epoch, fetched_del_epoch, 
                                         fetched_series, new_series, 
                                         new_references, 
                                         locally_observed_epoch_, candidates, 
                                         locally_observed_epoch >>

DropChunkData(self) == /\ pc[self] = "DropChunkData"
                       /\ \E series_to_drop \in SeriesId:
                            series_referenced_from_data' = series_referenced_from_data \ {series_to_drop}
                       /\ pc' = [pc EXCEPT ![self] = "BgWorkerTxBegin"]
                       /\ UNCHANGED << now, current_epoch, delete_epoch, 
                                       series_metadata, cached_series, 
                                       observed_epochs, fetched_cur_epoch, 
                                       fetched_del_epoch, fetched_series, 
                                       new_series, new_references, 
                                       locally_observed_epoch_, candidates, 
                                       locally_observed_epoch >>

MarkUnused(self) == /\ pc[self] = "MarkUnused"
                    /\ locally_observed_epoch' = [locally_observed_epoch EXCEPT ![self] = Max({current_epoch, now})]
                    /\ LET stale_series == {s \in StoredSeries:
                                            /\ (s \notin series_referenced_from_data)
                                           
                                           
                                           
                                           
                                            /\ (s \notin MarkedSeries)
                                            } IN
                         series_metadata' = [s \in stale_series |-> EntryMarkedForDeletion(locally_observed_epoch'[self])] @@ series_metadata
                    /\ pc' = [pc EXCEPT ![self] = "AdvanceEpoch"]
                    /\ UNCHANGED << now, current_epoch, delete_epoch, 
                                    series_referenced_from_data, cached_series, 
                                    observed_epochs, fetched_cur_epoch, 
                                    fetched_del_epoch, fetched_series, 
                                    new_series, new_references, 
                                    locally_observed_epoch_, candidates >>

AdvanceEpoch(self) == /\ pc[self] = "AdvanceEpoch"
                      /\ current_epoch' = Max({current_epoch, locally_observed_epoch[self]})
                      /\ pc' = [pc EXCEPT ![self] = "BgWorkerTxBegin"]
                      /\ UNCHANGED << now, delete_epoch, series_metadata, 
                                      series_referenced_from_data, 
                                      cached_series, observed_epochs, 
                                      fetched_cur_epoch, fetched_del_epoch, 
                                      fetched_series, new_series, 
                                      new_references, locally_observed_epoch_, 
                                      candidates, locally_observed_epoch >>

PrepareDeleteTx(self) == /\ pc[self] = "PrepareDeleteTx"
                         /\ delete_epoch' = Max({current_epoch - Delay, delete_epoch})
                         /\ locally_observed_epoch' = [locally_observed_epoch EXCEPT ![self] = delete_epoch']
                         /\ pc' = [pc EXCEPT ![self] = "ActuallyDeleteTx"]
                         /\ UNCHANGED << now, current_epoch, series_metadata, 
                                         series_referenced_from_data, 
                                         cached_series, observed_epochs, 
                                         fetched_cur_epoch, fetched_del_epoch, 
                                         fetched_series, new_series, 
                                         new_references, 
                                         locally_observed_epoch_, candidates >>

ActuallyDeleteTx(self) == /\ pc[self] = "ActuallyDeleteTx"
                          /\ candidates' = [candidates EXCEPT ![self] = MarkedAndRipe(locally_observed_epoch[self]) \ NewDataAfterMarked]
                          /\ series_metadata' = [x \in candidates'[self] |-> NoEntry] @@ series_metadata
                          /\ pc' = [pc EXCEPT ![self] = "Ressurect"]
                          /\ UNCHANGED << now, current_epoch, delete_epoch, 
                                          series_referenced_from_data, 
                                          cached_series, observed_epochs, 
                                          fetched_cur_epoch, fetched_del_epoch, 
                                          fetched_series, new_series, 
                                          new_references, 
                                          locally_observed_epoch_, 
                                          locally_observed_epoch >>

Ressurect(self) == /\ pc[self] = "Ressurect"
                   /\ series_metadata' = [x \in (MarkedAndRipe(locally_observed_epoch[self]) \ candidates[self]) |-> NewEntry] @@ series_metadata
                   /\ pc' = [pc EXCEPT ![self] = "BgWorkerTxBegin"]
                   /\ UNCHANGED << now, current_epoch, delete_epoch, 
                                   series_referenced_from_data, cached_series, 
                                   observed_epochs, fetched_cur_epoch, 
                                   fetched_del_epoch, fetched_series, 
                                   new_series, new_references, 
                                   locally_observed_epoch_, candidates, 
                                   locally_observed_epoch >>

bg_worker(self) == BgWorkerTxBegin(self) \/ DropChunkData(self)
                      \/ MarkUnused(self) \/ AdvanceEpoch(self)
                      \/ PrepareDeleteTx(self) \/ ActuallyDeleteTx(self)
                      \/ Ressurect(self)

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == (\E self \in CacheRefreshWorkers: cache_refresh_worker(self))
           \/ (\E self \in Ingesters: ingester(self))
           \/ (\E self \in BgWorkers: bg_worker(self))
           \/ Terminating

Spec == Init /\ [][Next]_vars

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION 

(* 
 * If a series appears as new then at least sometimes it is stored.
 *
 * This is a pretty weak liveness property, but this spec's main focus
 * is safety. This property exists mainly to guard against a spec
 * that doesn't insert any data and thus trivally satisifies safety.
 *)
NewSeriesAreStored == <>(
    \A i \in Ingesters: (
        \A s \in SeriesId: 
            s \in new_series[i] => series_metadata[s].stored = TRUE
    ))

====================================================================
