# Run from the repository root. Data and annotation outputs stay local.
library(dplyr)
library(jsonlite)
data_dir <- Sys.getenv("STORM_DATA_DIR", "data")
if (!dir.exists(data_dir)) stop("Create the data directory or set STORM_DATA_DIR; see README.md.")
setwd(data_dir)
watershed_id <- Sys.getenv("STORM_WATERSHED", "niles")
flow_tz <- Sys.getenv("STORM_TIMEZONE", "Etc/GMT+5")
flow_csv <- Sys.getenv("STORM_FLOW_CSV", "niles2000_2026.csv")
if (file.exists(flow_csv)) {
  niles <- read.csv(flow_csv)
} else if (watershed_id == "niles" && file.exists("nwis.waterdata.usgs.gov.txt")) {
  raw <- read.delim("nwis.waterdata.usgs.gov.txt", comment.char = "#", colClasses = "character")
  raw <- raw[-1, , drop = FALSE]
  names(raw)[names(raw) == "X71813_00060"] <- "discharge_cfs"
  niles <- raw
} else stop("Flow CSV missing; provide datetime and discharge_cfs columns.")
stopifnot(all(c("datetime", "discharge_cfs") %in% names(niles)))
niles$datetime <- as.POSIXct(niles$datetime, format = "%Y-%m-%d %H:%M", tz = flow_tz)
niles$discharge_l_s <- as.numeric(niles$discharge_cfs) * 28.316847
if (anyNA(niles$datetime) || anyDuplicated(niles$datetime)) stop("Discharge timestamps must be valid and unique.")
if (any(niles$discharge_l_s < 0, na.rm = TRUE)) stop("Discharge must be nonnegative.")
precip_cache <- Sys.getenv("STORM_PRECIP_CACHE", paste0(watershed_id, "_era5_point_precip.rds"))
# Reuse the established Niles cache when no new cache is specified.
if (watershed_id == "niles" && !nzchar(Sys.getenv("STORM_PRECIP_CACHE")) && file.exists("era5_point_precip.rds"))
  precip_cache <- "era5_point_precip.rds"
if (file.exists(precip_cache)) {
  precip <- readRDS(precip_cache)
} else {
  lat <- as.numeric(Sys.getenv("STORM_LAT", "41.95"))
  lon <- as.numeric(Sys.getenv("STORM_LON", "-85.55"))
  if (watershed_id != "niles" && (!nzchar(Sys.getenv("STORM_LAT")) || !nzchar(Sys.getenv("STORM_LON"))))
    stop("Set STORM_LAT and STORM_LON for another watershed before downloading ERA5.")
  start <- Sys.getenv("STORM_PRECIP_START", format(min(niles$datetime), "%Y-%m-%d"))
  end <- Sys.getenv("STORM_PRECIP_END", format(min(max(niles$datetime), Sys.time() - 86400), "%Y-%m-%d"))
  options(timeout = 300)
  url <- paste0("https://archive-api.open-meteo.com/v1/archive?latitude=", lat,
    "&longitude=", lon, "&start_date=", start, "&end_date=", end,
    "&hourly=precipitation&models=era5&timezone=GMT")
  j <- fromJSON(url)
  precip <- data.frame(time = as.POSIXct(j$hourly$time, format = "%Y-%m-%dT%H:%M", tz = "UTC"),
    precip_mm = j$hourly$precipitation)
  saveRDS(precip, precip_cache)
}
stopifnot(all(c("time", "precip_mm") %in% names(precip)), inherits(precip$time, "POSIXct"))
attr(precip$time, "tzone") <- flow_tz

library(shiny)
library(plotly)
library(dplyr)

# ---- settings ----
watershed_id <- Sys.getenv("STORM_WATERSHED", "niles")
out_file    <- paste0(watershed_id, "_events_precip.csv") #   # saved in your working directory
window_days <- 360                          # days shown at once
step_frac   <- 0.8                         # Next/Previous move 80% of a window

if (!exists("precip")) precip <- readRDS(precip_cache)

dat <- niles  %>% arrange(datetime) %>% mutate(idx = row_number())
pr  <- precip %>% select(time, precip_mm) %>% arrange(time) %>% mutate(pidx = row_number())
fmt <- function(x) format(x, "%Y-%m-%d %H:%M")

events <- if (file.exists(out_file)) {
  read.csv(out_file, stringsAsFactors = FALSE)
} else {
  data.frame(event_id = integer(), start_idx = integer(), peak_idx = integer(),
             end_idx = integer(), start = character(), peak = character(),
             end = character(), peak_l_s = numeric(),
             precip_start_idx = integer(), precip_end_idx = integer(),
             precip_start = character(), precip_end = character(),
             total_precip_mm = numeric(), max_precip_mm_h = numeric(),
             lag_rainstart_to_peak_h = numeric(), stringsAsFactors = FALSE)
}

# Legacy labels are retained with unspecified annotation fields.
annotation_defaults <- list(watershed = watershed_id, structure = "Unspecified",
  start_confidence = "Unspecified", end_confidence = "Unspecified",
  cause = "Unknown", completeness = "Unspecified", endpoint_basis = "Unspecified",
  notes = "", secondary_indices = "", earliest_end = "", latest_end = "",
  annotation_version = "manual-v1")
for (nm in names(annotation_defaults)) {
  if (!nm %in% names(events)) events[[nm]] <- rep(annotation_defaults[[nm]], nrow(events))
}
review_file <- paste0(watershed_id, "_reviewed_intervals.csv")
reviewed <- if (file.exists(review_file)) read.csv(review_file) else
  data.frame(start = character(), end = character(), label = character(), watershed = character())
history_dir <- paste0(watershed_id, "_annotation_history")
archive_events <- function(e) {
  dir.create(history_dir, showWarnings = FALSE)
  path <- tempfile(pattern = paste0(format(Sys.time(), "%Y%m%d-%H%M%S"), "-"),
                   tmpdir = history_dir, fileext = ".csv")
  write.csv(e, path, row.names = FALSE)
}

# Start where you left off, or at the beginning of the record
first_view <- if (nrow(events) > 0) {
  dat$datetime[max(events$end_idx)] - 5 * 86400
} else {
  min(dat$datetime)
}

ui <- fluidPage(
  tags$head(tags$style(HTML("
    html, body { min-height:100%; margin:0; overflow-x:hidden; overflow-y:auto; }
    body > .container-fluid { padding:0; }
    .storm-shell { height:100vh; height:100dvh; display:flex; flex-direction:column; overflow:hidden; }
    .storm-title { margin:0; padding:10px 14px; font-size:20px; flex:none; }
    .storm-workspace { display:grid; grid-template-columns:clamp(110px,30vw,280px) minmax(0,1fr); flex:1; min-height:0; }
    .storm-sidebar { overflow:auto; min-height:0; padding:12px; background:#f5f5f5; border-right:1px solid #ddd; }
    .storm-sidebar h3 { font-size:17px; margin:0 0 12px; }
    .storm-sidebar .form-group { margin-bottom:10px; }
    .storm-sidebar .shiny-input-container { width:100%; }
    .storm-sidebar .btn { white-space:normal; max-width:100%; margin-bottom:6px; }
    .storm-sidebar details { margin-top:14px; }
    .storm-sidebar summary { font-weight:600; cursor:pointer; }
    .storm-main { min-width:0; min-height:0; display:flex; flex-direction:column; padding:10px; overflow:hidden; }
    .storm-nav { display:flex; flex-wrap:wrap; gap:6px; align-items:center; flex:none; }
    .storm-nav .shiny-input-container { width:145px; margin:0; }
    .storm-status { font-size:14px; margin:8px 0 4px; flex:none; }
    .storm-help { font-size:12px; margin:0 0 4px; flex:none; }
    .storm-graph { flex:1; min-height:0; min-width:0; position:relative; }
    #hydro { position:absolute; inset:0; height:100% !important; width:100% !important; }
    .storm-table { overflow:auto; max-height:320px; }
    .storm-saved-section { padding:16px; }
    .storm-saved-section .storm-table { max-height:none; overflow-x:auto; }
    @media(max-width:600px) {
      .storm-sidebar { padding:6px; font-size:12px; }
      .storm-sidebar .form-control,.storm-sidebar .selectize-input { font-size:12px; }
      .storm-main { padding:5px; }
      .storm-title { font-size:16px; padding:6px; }
      .storm-nav .btn { font-size:12px; padding:4px 6px; }
      .storm-status { font-size:12px; }
    }
  "))),
  div(class = "storm-shell",
    h2(class = "storm-title", "Storm event delineation: flow + precipitation"),
    div(class = "storm-workspace",
      div(class = "storm-sidebar",
        h3("Event annotation"),
        selectInput("selected_event", "Review saved storm", choices = c("New event" = "")),
        actionButton("load_event", "Load for editing"),
        selectInput("click_mode", "Discharge click action", choices = c(
          "Event boundaries" = "boundaries", "Add secondary peak" = "peak",
          "Earliest plausible end" = "early", "Latest plausible end" = "late",
          "Non-event interval" = "non_event")),
        actionButton("clear_peaks", "Clear secondary peaks"),
        selectInput("structure", "Event structure", c("Unspecified", "Single peak", "Compound")),
        selectInput("cause", "Likely cause", c("Unknown", "Rainfall", "Possible snowmelt", "Mixed")),
        selectInput("start_confidence", "Start confidence", c("Unspecified", "Clear", "Approximate", "Uncertain")),
        selectInput("end_confidence", "End confidence", c("Unspecified", "Clear", "Approximate", "Uncertain")),
        selectInput("completeness", "Completeness", c("Unspecified", "Complete", "Data gap", "Record boundary")),
        selectInput("endpoint_basis", "Endpoint basis", c("Unspecified", "Recovery toward baseflow", "Interrupted by another rise", "Other")),
        textAreaInput("notes", "Notes", width = "100%"),
        textOutput("annotation_detail"),
        actionButton("save_annotation", "Save annotation / edits"),
        actionButton("skip_precip", "No rain - save"),
        actionButton("cancel", "Cancel current event"),
        actionButton("undo", "Undo last event"),
        downloadButton("export_labels", "Export training labels"),
        tags$details(tags$summary("Reviewed non-event intervals"),
          actionButton("undo_review", "Remove last non-event interval"),
          div(class="storm-table", tableOutput("reviewed_table")))
      ),
      div(class = "storm-main",
        div(class = "storm-nav",
          actionButton("prev", "\u25C0 Previous"), actionButton("next_win", "Next \u25B6"),
          dateInput("jump", NULL, value = as.Date(first_view))),
        h4(class = "storm-status", textOutput("status")),
        p(class = "storm-help", "Drag green boundaries sideways. Load a saved storm to edit; save to confirm."),
        div(class = "storm-graph", plotlyOutput("hydro", height = "100%"))
      )
    )
  ),
  div(class = "storm-saved-section", h3("Saved storms"),
    div(class = "storm-table", tableOutput("saved_storms"))),
  tags$script(HTML("new ResizeObserver(function(){window.dispatchEvent(new Event('resize'));}).observe(document.querySelector('.storm-graph'));"))
)

server <- function(input, output, session) {
  view_start <- reactiveVal(first_view)
  ev         <- reactiveVal(events)
  stage      <- reactiveVal(1)       # 1 flow start, 2 flow end, 3 rain start, 4 rain end
  cur        <- reactiveVal(list())  # clicks for the event in progress
  boundary_keys <- reactiveVal(character())
  boundary_revision <- reactiveVal(0L)
  editing <- reactiveVal(NULL)
  reviews <- reactiveVal(reviewed)
  non_start <- reactiveVal(NULL)
  observe({
    e <- ev()
    updateSelectInput(session, "selected_event", choices = c("New event" = "",
      setNames(as.character(e$event_id), if (nrow(e)) paste("Storm", e$event_id, e$start) else character())),
      selected = if (is.null(editing())) "" else as.character(editing()))
  })
  persist <- function(e) {
    archive_events(ev())
    write.csv(e, out_file, row.names = FALSE)
    ev(e)
  }
  apply_annotation <- function(row) {
    for (nm in c("structure", "start_confidence", "end_confidence", "cause", "completeness", "endpoint_basis", "notes")) {
      value <- input[[nm]]
      if (!is.null(value)) row[[nm]] <- value
    }
    cc <- cur()
    row$secondary_indices <- paste(sort(unique(cc$secondary)), collapse = ";")
    row$earliest_end <- if (is.null(cc$early)) "" else fmt(dat$datetime[cc$early])
    row$latest_end <- if (is.null(cc$late)) "" else fmt(dat$datetime[cc$late])
    row
  }
  observeEvent(input$load_event, {
    req(nzchar(input$selected_event))
    row <- ev()[ev()$event_id == as.integer(input$selected_event), , drop = FALSE]
    req(nrow(row) == 1)
    sec <- as.integer(strsplit(ifelse(is.na(row$secondary_indices), "", row$secondary_indices), ";")[[1]])
    find_time <- function(value) if (is.na(value) || !nzchar(value)) NULL else match(value, fmt(dat$datetime))
    cur(list(fs = row$start_idx, fe = row$end_idx,
      ps = if (is.na(row$precip_start_idx)) NULL else row$precip_start_idx,
      pe = if (is.na(row$precip_end_idx)) NULL else row$precip_end_idx,
      secondary = sec[!is.na(sec)], early = find_time(row$earliest_end), late = find_time(row$latest_end)))
    editing(row$event_id); stage(1)
    view_start(dat$datetime[row$start_idx] - 86400)
    for (nm in c("structure", "start_confidence", "end_confidence", "cause", "completeness", "endpoint_basis"))
      updateSelectInput(session, nm, selected = row[[nm]])
    updateTextAreaInput(session, "notes", value = row$notes)
    updateSelectInput(session, "click_mode", selected = "boundaries")
  })
  observeEvent(input$clear_peaks, { cc <- cur(); cc$secondary <- NULL; cur(cc) })
  output$annotation_detail <- renderText({
    cc <- cur()
    paste("Editing:", if (is.null(editing())) "new event" else paste("storm", editing()),
      "| Secondary peaks:", length(cc$secondary), "| Earliest end:",
      if (is.null(cc$early)) "unset" else fmt(dat$datetime[cc$early]),
      "| Latest end:", if (is.null(cc$late)) "unset" else fmt(dat$datetime[cc$late]))
  })
  observeEvent(input$undo_review, {
    r <- reviews()
    if (nrow(r)) {
      r <- r[-nrow(r), , drop = FALSE]
      write.csv(r, review_file, row.names = FALSE); reviews(r)
    }
  })
  output$reviewed_table <- renderTable(reviews(), striped = TRUE)
  output$export_labels <- downloadHandler(
    filename = function() paste0(watershed_id, "_training_labels.zip"),
    content = function(file) {
      folder <- tempfile(); dir.create(folder)
      e <- ev()
      write.csv(e, file.path(folder, "events.csv"), row.names = FALSE)
      peaks <- data.frame(event_id = integer(), watershed = character(), time = character(),
        discharge_l_s = numeric(), role = character())
      for (k in seq_len(nrow(e))) {
        secondary <- as.integer(strsplit(ifelse(is.na(e$secondary_indices[k]), "", e$secondary_indices[k]), ";")[[1]])
        indices <- unique(c(e$peak_idx[k], secondary[!is.na(secondary)]))
        peaks <- rbind(peaks, data.frame(event_id = e$event_id[k], watershed = watershed_id,
          time = fmt(dat$datetime[indices]), discharge_l_s = dat$discharge_l_s[indices],
          role = ifelse(indices == e$peak_idx[k], "primary maximum", "manual secondary")))
      }
      write.csv(peaks, file.path(folder, "peaks.csv"), row.names = FALSE)
      write.csv(reviews(), file.path(folder, "reviewed_intervals.csv"), row.names = FALSE)
      old <- setwd(folder); on.exit({setwd(old); unlink(folder, recursive = TRUE)}, add = TRUE)
      utils::zip(file, c("events.csv", "peaks.csv", "reviewed_intervals.csv"))
    })
  step       <- window_days * 86400 * step_frac

  output$saved_storms <- renderTable({
    e <- ev()
    data.frame(
      `Storm ID` = e$event_id, `Structure` = e$structure,
      `End confidence` = e$end_confidence, `Cause` = e$cause,
      `Flow start` = e$start, `Flow peak` = e$peak, `Flow end` = e$end,
      `Peak (L/s)` = e$peak_l_s,
      `Rain start` = e$precip_start, `Rain end` = e$precip_end,
      `Total rain (mm)` = e$total_precip_mm,
      `Max rain (mm/h)` = e$max_precip_mm_h,
      `Rain start to peak (h)` = e$lag_rainstart_to_peak_h,
      check.names = FALSE)
  }, striped = TRUE, bordered = TRUE, digits = 2, na = "\u2014")

  # ---- navigation and buttons ----
  observeEvent(input$prev,     view_start(view_start() - step))
  observeEvent(input$next_win, view_start(view_start() + step))
  observeEvent(input$jump, {
    view_start(as.POSIXct(as.character(input$jump), tz = attr(dat$datetime, "tzone")))
  }, ignoreInit = TRUE)
  observeEvent(input$cancel, {
    stage(1); cur(list()); editing(NULL); non_start(NULL)
    for (nm in c("structure", "start_confidence", "end_confidence", "completeness", "endpoint_basis"))
      updateSelectInput(session, nm, selected = "Unspecified")
    updateSelectInput(session, "cause", selected = "Unknown")
    updateTextAreaInput(session, "notes", value = "")
  })
  observeEvent(input$undo, {
    e <- ev()
    if (nrow(e) > 0) {
      e <- e[-nrow(e), ]
      persist(e)
      editing(NULL); cur(list()); stage(1)
    }
  })

  # ---- save an event (rain indices optional) ----
  save_event <- function(ps = NA, pe = NA) {
    cc <- cur()
    s  <- min(cc$fs, cc$fe)
    en <- max(cc$fs, cc$fe)
    if (s == en || !any(is.finite(dat$discharge_l_s[s:en]))) {
      showNotification("Choose a nonzero interval with valid discharge.", type = "error"); return()
    }
    if (any(cc$secondary < s | cc$secondary > en)) {
      showNotification("Secondary peaks must lie within the flow interval.", type = "error"); return()
    }
    if ((!is.null(cc$early) && (cc$early < s || cc$early > en)) ||
        (!is.null(cc$late) && cc$late < en)) {
      showNotification("End bounds must bracket the chosen end and follow the start.", type = "error"); return()
    }
    r <- reviews()
    if (nrow(r) > 0 && any(r$start <= fmt(dat$datetime[en]) & r$end >= fmt(dat$datetime[s]))) {
      showNotification("This event overlaps a confirmed non-event interval. Review that interval first.", type = "error"); return()
    }
    pk <- s - 1 + which.max(dat$discharge_l_s[s:en])
    has_p <- !is.na(ps)
    if (has_p) { a <- min(ps, pe); pe <- max(ps, pe); ps <- a }

    e <- ev()
    new <- data.frame(
      event_id  = if (!is.null(editing())) editing() else if (nrow(e) == 0) 1 else max(e$event_id) + 1,
      start_idx = s, peak_idx = pk, end_idx = en,
      start = fmt(dat$datetime[s]), peak = fmt(dat$datetime[pk]),
      end   = fmt(dat$datetime[en]),
      peak_l_s = dat$discharge_l_s[pk],
      precip_start_idx = ps, precip_end_idx = pe,
      precip_start    = if (has_p) fmt(pr$time[ps]) else NA,
      precip_end      = if (has_p) fmt(pr$time[pe]) else NA,
      total_precip_mm = if (has_p) sum(pr$precip_mm[ps:pe], na.rm = TRUE) else NA,
      max_precip_mm_h = if (has_p) max(pr$precip_mm[ps:pe], na.rm = TRUE) else NA,
      lag_rainstart_to_peak_h = if (has_p) {
        as.numeric(difftime(dat$datetime[pk], pr$time[ps], units = "hours"))
      } else NA,
      stringsAsFactors = FALSE)

    for (nm in names(annotation_defaults)) new[[nm]] <- annotation_defaults[[nm]]
    new <- apply_annotation(new)
    overlaps <- e$event_id != new$event_id & e$start_idx <= en & e$end_idx >= s
    if (any(overlaps)) showNotification("This interval overlaps an existing storm; review the labels.", duration = 10)
    e <- e[e$event_id != new$event_id, , drop = FALSE]
    e <- rbind(e, new[, names(e), drop = FALSE])
    persist(e)
    editing(new$event_id)
    cc$fs <- s; cc$fe <- en
    cc$ps <- if (has_p) ps else NULL; cc$pe <- if (has_p) pe else NULL
    cur(cc); stage(1)
  }

  observeEvent(input$save_annotation, {
    cc <- cur()
    if (is.null(cc$fs) || is.null(cc$fe)) {
      showNotification("Select or load a flow interval first.", type = "warning"); return()
    }
    if (xor(is.null(cc$ps), is.null(cc$pe))) {
      showNotification("Finish both rainfall boundaries first.", type = "warning"); return()
    }
    save_event(if (is.null(cc$ps)) NA else cc$ps, if (is.null(cc$pe)) NA else cc$pe)
  })

  observeEvent(input$skip_precip, {
    if (stage() == 3) save_event()
    else showNotification("Pick the flow start and end first.", type = "warning")
  })

  # ---- clicks ----
  observeEvent(event_data("plotly_click", source = "hydro", priority = "event"), {
    click <- event_data("plotly_click", source = "hydro", priority = "event")
    cd <- as.character(click$customdata[1])
    if (length(cd) == 0 || is.na(cd)) return()
    kind <- substr(cd, 1, 1)                 # "q" = discharge, "p" = precipitation
    i    <- as.integer(substring(cd, 3))
    if (is.na(i) || !kind %in% c("q", "p")) return()
    st   <- stage()
    cc   <- cur()
    mode <- input$click_mode
    if (!is.null(mode) && mode != "boundaries") {
      if (kind != "q") { showNotification("Click the discharge plot."); return() }
      if (mode == "non_event") {
        if (is.null(non_start())) non_start(i) else {
          a <- min(non_start(), i); z <- max(non_start(), i)
          if (a == z || any(ev()$start_idx <= z & ev()$end_idx >= a)) {
            showNotification("Non-event interval must have duration and cannot overlap saved storms.", type = "error")
          } else {
            r <- rbind(reviews(), data.frame(start = fmt(dat$datetime[a]), end = fmt(dat$datetime[z]),
              label = "confirmed non-event", watershed = watershed_id))
            write.csv(r, review_file, row.names = FALSE); reviews(r)
          }
          non_start(NULL)
        }
      } else {
        if (is.null(cc$fs) || is.null(cc$fe)) { showNotification("Select or load an event first."); return() }
        if (mode == "peak") cc$secondary <- unique(c(cc$secondary, i))
        if (mode == "early") cc$early <- i
        if (mode == "late") cc$late <- i
        cur(cc)
      }
      return()
    }

    if (st %in% 1:2 && kind != "q") {
      showNotification("Click the DISCHARGE plot (bottom) for the flow event.", type = "warning")
      return()
    }
    if (st %in% 3:4 && kind != "p") {
      showNotification("Click the PRECIPITATION plot (top), or press 'No rain - save'.", type = "warning")
      return()
    }

    if (st == 1)      { cc$fs <- i; cc$fe <- NULL; cc$ps <- NULL; cc$pe <- NULL; cur(cc); stage(2) }
    else if (st == 2) { cc$fe <- i; cur(cc); stage(3) }
    else if (st == 3) { cc$ps <- i; cur(cc); stage(4) }
    else              { save_event(cc$ps, i) }
  })

  # ---- data for the current window ----
  win <- reactive({
    w <- dat %>% filter(datetime >= view_start(),
                        datetime <  view_start() + window_days * 86400)
    e <- ev()
    in_ev <- rep(FALSE, nrow(w))
    for (k in seq_len(nrow(e))) {
      in_ev <- in_ev | (w$idx >= e$start_idx[k] & w$idx <= e$end_idx[k])
    }
    cc <- cur()
    marks <- c(cc$fs, cc$fe)
    w$event_q <- ifelse(in_ev, w$discharge_l_s, NA)
    w$peak_q  <- ifelse(w$idx %in% e$peak_idx, w$discharge_l_s, NA)
    w$secondary_q <- ifelse(w$idx %in% cc$secondary, w$discharge_l_s, NA)
    w$mark_q  <- ifelse(w$idx %in% marks, w$discharge_l_s, NA)
    w
  })

  pwin <- reactive({
    pw <- pr %>% filter(time >= view_start(),
                        time <  view_start() + window_days * 86400)
    e <- ev()
    in_p <- rep(FALSE, nrow(pw))
    for (k in seq_len(nrow(e))) {
      if (!is.na(e$precip_start_idx[k])) {
        in_p <- in_p | (pw$pidx >= e$precip_start_idx[k] & pw$pidx <= e$precip_end_idx[k])
      }
    }
    cc <- cur()
    pw$saved_p <- ifelse(in_p, pw$precip_mm, NA)
    pw$mark_p  <- ifelse(pw$pidx %in% cc$ps, pw$precip_mm, NA)
    pw
  })

  # ---- plot ----
  output$hydro <- renderPlotly({
    w  <- win()
    pw <- pwin()
    cc <- cur()

    top <- plot_ly(pw, x = ~time, customdata = ~paste0("p_", pidx), source = "hydro") %>%
      add_bars(y = ~precip_mm, name = "Precip", marker = list(color = "#9ecae1")) %>%
      add_bars(y = ~saved_p, name = "Saved rain", marker = list(color = "#08519c")) %>%
      # thin line so hours with zero rain can still be clicked
      add_lines(y = ~precip_mm, name = "Precip line", showlegend = FALSE,
                line = list(color = "#9ecae1", width = 1)) %>%
      add_markers(y = ~mark_p, name = "Rain start",
                  marker = list(color = "green", size = 12, symbol = "triangle-down"))

    bottom <- plot_ly(w, x = ~datetime, customdata = ~paste0("q_", idx), source = "hydro") %>%
      add_lines(y = ~discharge_l_s, name = "Discharge",
                line = list(color = "#89CFF0", width = 2)) %>%
      add_lines(y = ~event_q, name = "Saved events",
                line = list(color = "orange", width = 4), connectgaps = FALSE) %>%
      add_markers(y = ~peak_q, name = "Peaks", marker = list(color = "red", size = 9)) %>%
      add_markers(y = ~mark_q, name = "Flow start/end",
                  marker = list(color = "green", size = 12, symbol = "triangle-up"))

    bottom <- bottom %>% add_markers(y = ~secondary_q, name = "Manual secondary peaks",
      marker = list(color = "purple", size = 11, symbol = "diamond"))
    for (bound in c("early", "late")) {
      index <- cc[[bound]]
      if (!is.null(index) && index %in% w$idx) {
        bd <- w %>% filter(idx == index)
        bottom <- bottom %>% add_segments(data = bd, x = ~datetime, xend = ~datetime,
          y = 0, yend = ~discharge_l_s, inherit = FALSE, hoverinfo = "skip",
          name = paste(bound, "plausible end"), line = list(color = "purple", dash = "dot"))
      }
    }
    # Paper-height shapes align flow boundaries across discharge and rainfall.
    e <- ev()
    shape_keys <- character()
    boundary_shapes <- list()
    add_boundary <- function(index, key, color, editable) {
      if (is.null(index) || !index %in% w$idx) return()
      x <- as.numeric(dat$datetime[index]) * 1000
      boundary_shapes[[length(boundary_shapes) + 1L]] <<- list(
        type = "line", xref = "x", yref = "paper", x0 = x, x1 = x,
        y0 = 0, y1 = 1, editable = editable,
        line = list(color = color, width = if (editable) 6 else 2, dash = if (editable) "solid" else "dash"))
      shape_keys <<- c(shape_keys, key)
    }
    for (k in seq_len(nrow(e))) {
      if (!is.null(editing()) && e$event_id[k] == editing()) next
      add_boundary(e$start_idx[k], "saved", "orange", FALSE)
      add_boundary(e$end_idx[k], "saved", "orange", FALSE)
    }
    add_boundary(cc$fs, "fs", "green", TRUE)
    add_boundary(cc$fe, "fe", "green", TRUE)
    boundary_keys(shape_keys)

    # Dashed horizontal line at the flow-start level while the event is in progress
    if (!is.null(cc$fs) && nrow(w) > 0) {
      hl <- data.frame(x0 = min(w$datetime), x1 = max(w$datetime),
                       q  = dat$discharge_l_s[cc$fs])
      bottom <- bottom %>% add_segments(data = hl, x = ~x0, xend = ~x1, y = ~q, yend = ~q,
                                        name = "Start level", inherit = FALSE,
                                        line = list(color = "green", width = 2, dash = "dash"))
    }

    p <- subplot(top, bottom, nrows = 2, shareX = TRUE, heights = c(0.3, 0.7),
                 titleY = TRUE) %>%
      layout(hovermode = "x",
             barmode = "overlay", shapes = boundary_shapes,
             editrevision = paste(cc$fs, cc$fe, boundary_revision(), collapse = ":"),
             uirevision = as.character(view_start()),   # keep zoom while clicking
             yaxis  = list(title = "Precip (mm/h)", autorange = "reversed"),
             yaxis2 = list(title = "Discharge (L/s)"),
             legend = list(orientation = "h"))
    p <- plotly_build(p)
    p$x$layout$shapes <- boundary_shapes
    p <- config(p, responsive = TRUE, edits = list(shapePosition = TRUE))
    p <- event_register(p, "plotly_relayout")
    event_register(p, "plotly_click")
  })

  observeEvent(event_data("plotly_relayout", source = "hydro", priority = "event"), {
    change <- event_data("plotly_relayout", source = "hydro", priority = "event")
    keys <- boundary_keys()
    cc <- cur()
    moved <- FALSE
    for (nm in names(change)) {
      if (!grepl("^shapes\\[[0-9]+\\]\\.x[01]$", nm)) next
      position <- as.integer(sub("^shapes\\[([0-9]+)\\].*$", "\\1", nm)) + 1L
      if (position > length(keys) || !keys[position] %in% c("fs", "fe")) next
      value <- change[[nm]]
      time <- if (is.numeric(value)) as.POSIXct(value / 1000, origin = "1970-01-01", tz = "UTC") else
        as.POSIXct(gsub("T", " ", value, fixed = TRUE), tz = "UTC")
      if (is.na(time)) next
      index <- which.min(abs(as.numeric(dat$datetime) - as.numeric(time)))
      key <- keys[position]
      if ((key == "fs" && !is.null(cc$fe) && index >= cc$fe) ||
          (key == "fe" && !is.null(cc$fs) && index <= cc$fs)) {
        showNotification("Start must precede end. Boundary was not changed.", type = "warning")
        boundary_revision(boundary_revision() + 1L); next
      }
      cc[[key]] <- index
      moved <- TRUE
    }
    if (moved) {
      cur(cc)
      showNotification("Boundary adjusted. Save annotation / edits to record it.", duration = 3)
    }
  })

  output$status <- renderText({
    cc <- cur()
    msg <- switch(stage(),
                  "Step 1 of 4: click the FLOW START (bottom plot)",
                  paste0("Step 2 of 4: flow start ", fmt(dat$datetime[cc$fs]),
                         " \u2014 click the FLOW END (bottom plot)"),
                  "Step 3 of 4: click the RAIN START (top plot), or press 'No rain - save'",
                  paste0("Step 4 of 4: rain start ", fmt(pr$time[cc$ps]),
                         " \u2014 click the RAIN END (top plot)"))
    if (input$click_mode == "non_event") msg <- if (is.null(non_start()))
      "Click the start of a reviewed non-event interval" else "Click the end of the non-event interval"
    else if (input$click_mode != "boundaries") msg <- paste("Click discharge to mark:", input$click_mode)
    else if (!is.null(editing()) && !is.null(cc$fe) && stage() == 1)
      msg <- "Event loaded/saved: annotate and Save edits, or Cancel for a new event. Boundary clicks replace the flow interval."
    paste0(msg, "   |   Events saved: ", nrow(ev()),
           "   |   Showing ", format(view_start(), "%Y-%m-%d"), " to ",
           format(view_start() + window_days * 86400, "%Y-%m-%d"))
  })
}

runApp(shinyApp(ui, server))
