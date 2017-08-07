#' @name Store tracer
#' @title Stores given trace to the tracer
#'
#' @export
#'
store_trace <- function(tracer, trace) {
    UseMethod("store_trace")
}

#' @name Reset traces
#' @title Clears the captured traces
#'
#' @export
#'
reset_traces <- function(tracer) {
    UseMethod("reset_traces")
}

#' @name Copy call traces
#' @title Creates a copy of traces captured so far and returns them as R list.
#'
#' @export
#'
copy_traces <- function(tracer) {
    UseMethod("copy_traces")
}

#' @export
#'
copy_traces.default <- function(tracer) {
    tracer <- get_tracer()
    stopifnot(!is.null(tracer))
    copy_traces(tracer)
}

#' @export
#'
reset_traces.default <- function(tracer) {
    tracer <- get_tracer()
    stopifnot(!is.null(tracer))
    reset_traces(tracer)
}

#' @export
#'
set_tracer <- function(tracer) {
    old <- get_tracer()
    options(genthat.tracer=tracer)
    old
}

#' @export
#'
get_tracer <- function() {
    getOption("genthat.tracer")
}