# Default function entry decorator.
# Creates the trace record and stores it into the trace vector.
record_trace <- function(name, pkg=NULL, args, retv, error, seed,
                        env=parent.frame(), tracer=get_tracer()) {

    # TODO: (performance) all this makes sense only if there are symbols anywhere in args
    # get callee globals (free variables) that we need to capture
    # we do that by abusing the extract closure
    # TODO: will this help us with promises?

    trace <- tryCatch({
        ddsym <- as.character(filter(args, is_ddsym))
        if (length(ddsym) > 0) {
            names(ddsym) <- ddsym
            marker <- new.env(parent=emptyenv())

            vals <- lapply(ddsym, get_ddsym_value, env=env, marker=marker)
            args <- lapply(args, function(x) {
                if (is_ddsym(x) && !identical(vals[[as.character(x)]], marker)) {
                    # only replace the one which has been resolved
                    vals[[as.character(x)]]
                } else {
                    x
                }
            })
        }

        if (endsWith(name, "<-")) {
            # replacement function needs to be handle extra
            # cf. https://cran.r-project.org/doc/manuals/R-lang.html#Subset-assignment

            # instead of looking for *tmp* we need to find the actual name
            # in the parent frame
            tmp_name <- names(args)[[1]]
            value_name <- names(args)[[length(args)]]
            call_env <- sys.frame(sys.nframe() - 1)

            # we are trying to get the *tmp*
            if (exists("__genthat_tmp", envir=call_env)) {
                args[[tmp_name]] <- get("__genthat_tmp", envir=call_env)
            } else {
                stop("Unable to find __genthat_tmp for replacement function ", name)
            }
            # and the *value*
            if (exists(value_name, envir=call_env)) {
                args[[value_name]] <- get(value_name, envir=call_env)
            } else {
                stop("Unable to find ", value_name, " for replacement function ", name)
            }
        }

        callee <- as.function(c(alist(), as.call(c(quote(`{`), args))), envir=env)
        globals <- as.list(environment(extract_closure(callee)), all.names=TRUE)
        globals <- lapply(globals, duplicate_global_var)

        create_trace(name, pkg, args=args, globals=globals, retv=retv, seed=seed, error=error)
    }, error=function(e) {
        create_trace(name, pkg, args=args, failure=e)
    }, warning=function(e) {
        create_trace(name, pkg, args=args, failure=e)
    })

    store_trace(tracer, trace)
}

duplicate_global_var <- function(x) {
    if (is.null(x)) {
        x
    } else {
        create_duplicate(x)
    }
}

is_ddsym <- function(name) {
    if (is.name(name)) {
        name <- as.character(name)
    }

    is.character(name) && length(grep("^\\.\\.\\d+$", name)) == 1
}

get_ddsym_value <- function(sym, env, marker) {
    stopifnot(is.environment(env))
    stopifnot(is.environment(marker))

    sym <- as.character(sym)
    stopifnot(is_ddsym(sym))

    idx <- as.integer(substr(sym, 3, nchar(sym)))

    handler <- function(e) {
        if (is_debug_enabled()) {
            n <- sys.nframe() - 1
            while (n > 0) {
                if (identical(env, sys.frame(n))) {
                    break()
                } else {
                    n <- n - 1
                }
            }

            call <- if (n > 0) {
                format(sys.call(n))
            } else {
                "<unknown>"
            }

            cat("Unable to resolve", as.character(sym), "in", call, ":", e$message, "\n")
        }
        marker
    }

    tryCatch(get_dd_val(idx, env, marker, force=FALSE), error=handler, warning=handler)
}

find_symbol_env <- function(name, env=parent.frame(), .local=FALSE) {
    stopifnot(is.character(name), length(name) == 1)
    stopifnot(is.null(env) || is.environment(env))

    if (is.null(env) || identical(env, emptyenv())) {
        NULL
    } else if (exists(name, env, inherits=FALSE)) {
        if (is_imports_namespace(env)) {
            # we do not want to resolve symbol to an import namespace
            # this will be difficult to reference in the test
            find_symbol_env(name, parent.env(env), .local=.local)
        } else {
            if (!.local && exists(name, envir=env, inherits=FALSE, mode="function")) {
                # if it is a function, get its original environment
                fn <- get(name, envir=env, inherits=FALSE, mode="function")
                fn_env <- find_symbol_env(name, environment(fn), .local=TRUE)
                if (!is.null(fn_env)) {
                    fn_env
                } else {
                    # it is possible that the function is not defined in its
                    # associated environment in which case use the last one we
                    # found the symbol in
                    env
                }
            } else {
                env
            }
        }
    } else {
        find_symbol_env(name, parent.env(env), .local=.local)
    }
}

get_symbol_names <- function(exprs) {
    stopifnot(is.list(exprs))

    unique(unlist(lapply(exprs, all.names)))
}

get_symbol_values <- function(names, env=parent.frame(), include_base_symbols=FALSE) {
    if (length(names) == 0) {
        return(list())
    }

    stopifnot(is.character(names))
    stopifnot(is.environment(env))

    envs <- lapply(names, find_symbol_env, env=env)
    vars <- zip(name=names, env=envs)
    vars <- filter(vars, function(x) {
        if (is.null(x$env)) {
            # this can easily happen in the calls like dplyr::filter(data, x >
            # 0) since the `x` referes to an `x` in `data` not in environment
            # this we cannot know and thus we have to ignore it
            FALSE
        } else {
            TRUE
        }
    })

    if (!include_base_symbols) {
        vars <- filter_not(vars, function(x) is_base_env(x$env))
    }

    # TODO: use purrr
    lapply(vars, function(x) get_variable_value_or_reference(x$name, x$env))
}

get_variable_value_or_reference <- function(name, env) {
    pkg <- get_package_name(env)

    if (is_base_env(env)) {
        substitute(NAME, list(NAME=as.name(name)))
    } else if (is_package_environment(env)) {
        substitute(PKG::NAME, list(PKG=as.name(pkg), NAME=as.name(name)))
    } else if (is_package_namespace(env)) {
        if (name %in% getNamespaceExports(env)) {
            substitute(PKG::NAME, list(PKG=as.name(pkg), NAME=as.name(name)))
        } else {
            substitute(PKG:::NAME, list(PKG=as.name(pkg), NAME=as.name(name)))
        }
    } else {
        get(name, envir=env, inherits=FALSE)
    }
}

#' @importFrom codetools findGlobals
extract_closure <- function(fun, name=substitute(fun), .visited=list()) {
    stopifnot(is.closure(fun))

    if (isTRUE(attr(fun, "genthat_extracted_closure"))) {
        return(fun)
    }

    env <- environment(fun)
    if (identical(env, baseenv())
        || identical(env, .BaseNamespaceEnv)
        || identical(env, emptyenv())
        || environment_name(env) != "") {

        copy <- fun

        attr(copy, "genthat_extracted_closure") <- TRUE

        return(copy)
    }

    if (is.name(name) || is.character(name)) {
        .visited <- bag_add(.visited, name, env)
    }

    names <- codetools::findGlobals(fun)
    new_fun <-
        if (length(names) == 0) {
            copy <- fun
            environment(copy) <- new.env(parent=baseenv())
            copy
        } else {
            needs_link <- length(filter(names, bag_contains_value, bag=.visited, value=env)) > 0
            unknowns <- filter_not(names, bag_contains_value, bag=.visited, value=env)
            vals <- get_symbol_values(unknowns, env)

            vars <- filter_not(vals, is.closure)
            funs <- filter(vals, is.closure)

            # mark variables as visited so the consecutive serialization will not consider them
            .visited <- reduce(names(vars), function(b, x) b <- bag_add(b, x, env), init=.visited)

            # resolve free variables from composed structures
            # look for language objects in lists, pairlists and environments
            nested_langs_candidates <- filter(vars, function(x) is.list(x) || is.pairlist(x) || is.environment(x))
            nested_langs <- lapply(nested_langs_candidates, function(x) {
                if (is.environment(x)) x <- as.list(x)

                filter(x, function(y) is.language(y) && !is.formula(y))
            })
            nested_langs <- unlist(nested_langs, use.names=FALSE, recursive=FALSE)

            if (length(nested_langs) > 0) {
                nested_langs_globals <- lapply(nested_langs, function(x) {
                    call <- as.function(c(alist(), as.call(x)), env=env)
                    call_extracted <- extract_closure(call, .visited)
                    as.list(environment(call_extracted))
                })
                nested_langs_globals <- unlist(nested_langs_globals, use.names=TRUE, recursive=FALSE)
            } else {
                nested_langs_globals <- c()
            }

            # now we can process functions
            funs <- zip(name=names(funs), val=funs)
            funs <- lapply(funs, function(x) extract_closure(x$val, x$name, .visited))

            globals <- c(vars, nested_langs_globals, funs)

            new_env <-
                if (length(globals) == 0) {
                    new.env(parent=baseenv())
                } else {
                    e <- list2env(globals, parent=baseenv())
                    # we should only link the environments in the case it is necessary
                    # i.e. any of the global functions need access to this environment
                    # the idea is demonstrated in the test-capture.R
                    link_environments(e, .fun_filter=function(x) is.local_closure(x) && isTRUE(attr(x, "genthat_needs_link")))
                    e
                }

            f <- as.function(c(formals(fun), body(fun)), envir=new_env)
            if (needs_link) {
                attr(f, "genthat_needs_link") <- TRUE
            }
            f
        }

    attr(new_fun, "genthat_extracted_closure") <- TRUE
    new_fun
}
