source_text <- readLines('codefordelineations.R')
a <- which(source_text == 'library(shiny)')[1]
z <- which(source_text == 'runApp(shinyApp(ui, server))')[1]
original_dir <- getwd()
folder <- tempfile(); dir.create(folder); setwd(folder)
niles <- data.frame(datetime = as.POSIXct('2000-01-01', tz='UTC') + (0:99)*3600,
  discharge_l_s = 100 + 30*sin((0:99)/10))
precip <- data.frame(time=niles$datetime, precip_mm=rep(1,100))
eval(parse(text=source_text[a:(z-1)]))
shiny::testServer(server, {
  session$setInputs(click_mode='boundaries', structure='Compound', cause='Rainfall',
    start_confidence='Clear', end_confidence='Approximate', completeness='Complete',
    endpoint_basis='Recovery toward baseflow', notes='Test')
  cur(list(fs=2L,fe=30L,ps=2L,pe=10L,secondary=20L,early=28L,late=32L))
  save_event(2L,10L)
  stopifnot(nrow(ev()) == 1, ev()$structure == 'Compound', ev()$secondary_indices == '20')
  session$setInputs(selected_event='1', load_event=1)
  stopifnot(editing()==1, cur()$fe==30, cur()$secondary==20)
  session$setInputs(notes='Revised', save_annotation=1)
  stopifnot(nrow(ev())==1, ev()$notes=='Revised', length(list.files(history_dir))==2)
  cur(list(fs=2L, fe=30L, early=35L))
  save_event()
  stopifnot(nrow(ev())==1, ev()$notes=='Revised')
  cur(list(fs=2L,fe=30L,secondary=20L))
  widget <- jsonlite::fromJSON(output$hydro, simplifyVector=FALSE)
  stopifnot(length(widget$x$layout$shapes) == 2, widget$x$layout$shapes[[1]]$editable)
  boundary_keys(c("fs", "fe"))
  session$setInputs(`plotly_relayout-hydro` = jsonlite::toJSON(setNames(list(as.numeric(dat$datetime[4])*1000), "shapes[0].x0"), auto_unbox=TRUE))
  stopifnot(cur()$fs == 4L, cur()$fe == 30L)
  session$setInputs(`plotly_relayout-hydro` = jsonlite::toJSON(setNames(list(as.numeric(dat$datetime[3])*1000), "shapes[1].x0"), auto_unbox=TRUE))
  stopifnot(cur()$fe == 30L)
  output$saved_storms
  stopifnot(file.exists(out_file))
})
cat('Annotation save, load, edit, history, validation, table and plot checks passed\n')
setwd(original_dir)
unlink(folder,recursive=TRUE)
