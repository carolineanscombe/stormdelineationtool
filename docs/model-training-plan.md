# Storm identification across 25 gauges

## Objective and assumptions

Assume 25 streamflow gauges representing 25 catchments or nested catchments. If these are precipitation gauges feeding one streamflow record, the number of independently labeled streamflow sites is one, and precipitation becomes a spatial input instead. Site IDs, catchment boundaries, and upstream/downstream relationships must be documented.

Initial objective: retrospective segmentation of complete discharge records into manually defined runoff episodes and reviewed non-event periods. This is different from forecasting discharge or proving the physical source of water. The model learns the agreed annotation convention. Decide separately whether compound episodes or individual rainfall-driven pulses are the target. Never mix those definitions across annotators or watersheds.

## Candidate models in recommended order

1. **Interpretable baseline:** a discharge-rise/recession rule with tunable thresholds, or logistic regression using normalized discharge, changes, and antecedent rainfall. Thresholds are selected on training/validation data, not test sites. This provides a transparent benchmark.
2. **Gradient-boosted trees or random forest:** classify each time step using discharge level/percentile, multi-scale changes, rolling variability, rainfall accumulations, season, missingness, and watershed attributes. Convert probabilities to contiguous events with validation-selected persistence rules. Good first learned model when annotations are limited; inspect feature contributions and event failures. Prediction accuracy at individual time steps does not guarantee good episode boundaries.
3. **Temporal convolutional network (TCN), optionally a 1-D encoder-decoder:** output event probability at each time step directly from flow/rain sequences. Dilated convolutions can cover multi-day or multi-week context. A promising next experiment for hydrograph shapes and compound events; verify receptive field covers the longest episodes of interest. Multi-scale inputs may help combine hourly detail with long context. This is a proposed application, not a demonstrated best model for these sites.
4. **LSTM/GRU with watershed attributes:** learn sequential context jointly across sites. A static-attribute encoder can represent differences in area, storage, regulation, and climate. Compare against TCN and trees using the same labels and held-out sites. Multi-basin LSTM success in discharge simulation motivates this experiment but does not establish storm-segmentation accuracy.
5. **Transformer or river-network graph model, later:** consider only if simpler models plateau and enough independent labeled episodes exist. Graph models make sense if connected gauges provide a documented routing/network structure; unrelated catchments do not automatically justify a graph. Twenty-five gauges alone are not evidence of enough deep-learning training data.

For retrospective identification, future observations can be used deliberately to assess a recession. A real-time detector must be causal and will generally require delayed endpoint confirmation; train and evaluate those tasks separately.

## Required training package

| Dataset | Required fields |
| --- | --- |
| observations | gauge_id, interval/timestamp in UTC, discharge with units, precipitation interval/depth and source, quality flags, missingness; temperature/snow indicators where available |
| events | gauge_id + event_id, flow start/end, primary peak, single/compound, start/end confidence, optional plausible bounds, completeness, likely cause, endpoint basis, annotator, protocol version |
| peaks | gauge_id + event_id, each peak timestamp, primary/secondary role; optional independently labeled troughs |
| reviewed_intervals | gauge_id, start/end, reviewed coverage and explicit non-event labels; omit uncertain time from supervised negative labels |
| gauge_metadata | gauge_id, watershed ID, area, location, time convention, source, record coverage, regulation/land-use information, catchment relationships |

Keep original observations and reproducible preparation code. Do not train only on screenshots or event-summary rows: segmentation requires continuous sequences before, during, and after episodes. Primary peaks alone cannot teach starts/stops. The current app provides event, peak, and explicit negative-interval exports, but a dataset assembly step must add gauge IDs consistently, source/quality metadata, annotator identity, protocol version, and continuous observations.

Standardize intervals carefully: aggregate fine data to a justified common resolution or support multiple resolutions; do not invent hourly timing from daily observations. Preserve missing/trace/accumulated precipitation semantics. Normalize discharge using training data only; area-normalized flow is useful when drainage area is available. Do not use event totals, event maxima, or hand-selected end timestamps as prediction features: those reveal the target. A flow-only model should be compared with a flow-plus-precipitation model, especially before changing ERA5 to NOAA products.

## Annotation sampling

Start with a proposed 20–30 diverse episodes per gauge (500–750 across 25 streamflow gauges), plus substantial reviewed background periods. This is a planning target, not a proven minimum. Start with a smaller pilot if reviewing 25 sites is expensive. Include seasons, small/large responses, dry/wet antecedent conditions, single/compound events, long recessions, rain/snowmelt ambiguity, and regulated/noisy periods. Use complete reviewed blocks as well as targeted examples so event frequencies can be evaluated realistically. Extreme-event-only sampling biases the detector.

Double-label a subset spanning all sites and difficult cases. Record boundary disagreements. Mask uncertain boundary ranges or use confidence weighting rather than treating all timestamps as exact truth. Truncated events can teach interior event state but should not be used as known starts/ends. Plot learning curves to decide whether more labels or a different model are needed. Independent episodes and diversity matter more than millions of autocorrelated rows.

## Evaluation and leakage prevention

Use two evaluations: unseen later periods at known gauges, and entirely held-out watersheds. An illustrative split is 15 training, 5 validation, 5 test sites, subject to catchment grouping and representation; grouped cross-validation may be more stable with only 25 sites. Hold connected/nested catchments or highly related gauges together where evaluating geographic transfer. Keep whole episodes and overlapping context windows in one partition. Same regional storms across gauges can leak information; use region/date-grouped splits when testing event independence.

Tune preprocessing, features, class weights, persistence thresholds and hyperparameters using training/validation only. Report precision/recall and PR-AUC on reviewed time, event-level detection precision/recall with declared overlap matching, start/end timing errors, intersection-over-union, compound split/merge errors, and results by gauge and season. Avoid raw accuracy as the main metric because background time dominates. Assess endpoint errors against plausible ranges and annotator disagreement. Bootstrap by episodes/sites rather than treating adjacent hours as independent.

Use uncertainty-guided review only after a frozen baseline evaluation exists: annotate cases the model finds uncertain, while retaining untouched test data. No model is implemented or trained in this repository yet.

## Primary references

- [scikit-learn ensemble documentation](https://scikit-learn.org/stable/api/sklearn.ensemble.html): random forest and gradient-boosting classifier implementations.
- [Bai, Kolter, and Koltun (2018)](https://arxiv.org/abs/1803.01271): TCN sequence-modeling benchmarks; not a hydrological event-detection validation.
- [Kratzert et al. (2019)](https://arxiv.org/abs/1907.08456): multi-basin LSTM discharge modeling with static catchment attributes; not storm labeling.
- [NeuralHydrology EA-LSTM documentation](https://neuralhydrology.readthedocs.io/en/latest/api/neuralhydrology.modelzoo.ealstm.html): static-attribute-conditioned recurrent architecture.
- [Tarasova et al. (2018)](https://doi.org/10.1029/2018WR022587): hydrological event definitions and refinement of compound responses.
