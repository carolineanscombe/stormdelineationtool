# Storm delineation tool

R Shiny application for manually labeling streamflow response episodes and paired precipitation intervals. The graph and annotation sidebar occupy the first screen; the saved-storm table is below it.

## Run

Install R and these packages once:

```r
install.packages(c("shiny", "plotly", "dplyr", "jsonlite"))
```

From this repository, place your observations in the ignored `data/` directory, or set `STORM_DATA_DIR` to your existing data folder. Run:

```sh
STORM_DATA_DIR=/path/to/data Rscript codefordelineations.R
```

The default Niles input is `niles2000_2026.csv` with `datetime` and `discharge_cfs` columns. Datetimes must have format `YYYY-MM-DD HH:MM` and a documented time zone. The original Niles USGS text export is also supported as a fallback, using its specific discharge-column name. The app converts cfs to L/s. It uses a cached ERA5 precipitation RDS file, or downloads point precipitation through Open-Meteo if absent. Internet is needed only for that download. Data and labels are not included in this repository.

For the existing local setup:

```sh
STORM_DATA_DIR="$HOME/Desktop/AI_fellowship" Rscript codefordelineations.R
```

## Manual workflow

1. Select flow start and flow end on the bottom plot.
2. Select rain start and rain end on the top plot, or choose No rain - save.
3. Complete the annotation fields and press Save annotation / edits. Rain-end and No rain also save an initial event; subsequently save the completed annotations.
4. Use Discharge click action for manual secondary peaks, plausible end bounds, or two-click reviewed non-event intervals.
5. Load a saved storm to edit it. Drag solid green boundaries sideways; these snap to discharge observations. Save to persist the change. Orange boundaries show other saved storms.
6. Cancel current event resets the selection for a new event.

The horizontal green line is measured discharge at the chosen flow start, not estimated baseflow. No automated baseflow separation or storm boundary detection is implemented. The highest discharge within each selected interval is calculated automatically. Secondary peaks are manually selected. Zero rainfall is not inferred from missing precipitation.

## Other watersheds

Set the following environment variables before running; paths are relative to `STORM_DATA_DIR` unless absolute:

| Variable | Purpose / default |
| --- | --- |
| STORM_DATA_DIR | Input/output directory; `data` |
| STORM_WATERSHED | Unique watershed identifier; `niles` |
| STORM_FLOW_CSV | CSV with datetime and discharge_cfs; `niles2000_2026.csv` |
| STORM_TIMEZONE | Zone used to interpret flow timestamps; `Etc/GMT+5` (fixed EST, no DST) |
| STORM_PRECIP_CACHE | RDS with POSIXct time and precip_mm; watershed-specific default |
| STORM_LAT, STORM_LON | ERA5 point coordinates; required for downloading another watershed |
| STORM_PRECIP_START, STORM_PRECIP_END | Optional download dates; default to discharge coverage, ending no later than yesterday |

Use a unique watershed ID and precipitation cache per dataset. Do not replace or reorder discharge data after labeling: stored row indices refer to the original sorted observations. Outputs use the watershed ID. This app is intended for one annotator/session at a time; simultaneous sessions can overwrite each other's CSV edits.

## Outputs and checks

Exports contain events.csv, peaks.csv, and reviewed_intervals.csv. Only explicitly reviewed non-event intervals are negative labels; unreviewed time is unknown. Saved edits/undo operations keep preceding event snapshots in the local annotation-history directory. CSV labels and history are excluded from Git.

Run `Rscript tests/test_annotations.R` from the repository root. Synthetic-data checks exercise saving, loading, editing, snapshots, invalid bounds, plot shape serialization, and drag updates. They do not validate scientific event definitions.

Missing-data intervals require manual attention. Rain totals currently sum nonmissing values, so incomplete precipitation may produce a partial total. The point ERA5 series is supporting evidence, not a watershed-average rainfall measurement. Classification fields are human judgments. Agree on the provisional [annotation protocol](docs/annotation-protocol.md) before large-scale labeling.

See [model and training-data plan](docs/model-training-plan.md).
