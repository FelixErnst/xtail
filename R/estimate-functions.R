#########################################################
#
# These functions are copied and modify from DESeq2 package
#
#########################################################

## Xtail relies on DESeq2 to estimate coefficient of GLM model

#' @importFrom stats relevel formula terms
#' @importFrom S4Vectors mcols mcols<-
#' @importFrom SummarizedExperiment assay assay<-
.estimate_MLE_for_Beta <- function(object,
                                   modelMatrix = NULL,
                                   modelMatrixType = "standard",
                                   maxit = 100,
                                   useOptim = TRUE,
                                   quiet = FALSE,
                                   useQR = TRUE) {
    stopifnot(length(maxit)==1)

    # in case the class of the mcols(mcols(object)) are not character
    object <- .sanitize_rowData(object)

    if (is.null(mcols(object)$allZero)) {
        object <- .get_base_means_and_variances(object)
    }

    # only continue on the rows with non-zero row mean
    objectNZ <- object[!mcols(object)$allZero,,drop=FALSE]

    if (is.null(modelMatrix)) {
        modelAsFormula <- TRUE
        termsOrder <- attr(terms(design(object)),"order")
        interactionPresent <- any(termsOrder > 1)
        blindDesign <- design(object) == formula(~ 1)

        # store modelMatrixType so it can be accessed by estimateBetaPriorVar
        attr(object, "modelMatrixType") <- modelMatrixType
        hasIntercept <- attr(terms(design(object)),"intercept") == 1
        renameCols <- hasIntercept
    } else {
        message("using supplied model matrix")
        modelAsFormula <- FALSE
        attr(object, "modelMatrixType") <- "user-supplied"
        renameCols <- FALSE
    }


    # fit the negative binomial GLM without a prior
    # (in actuality a very wide prior with standard deviation 1e3 on log2 fold changes)
    fit <- .fit_Nbinom_GLMs(objectNZ,
                            maxit = maxit,
                            useOptim = useOptim,
                            useQR = useQR,
                            renameCols = renameCols,
                            modelMatrix = modelMatrix)
    H <- fit$hat_diagonals
    modelMatrix <- fit$modelMatrix
    modelMatrixNames <- fit$modelMatrixNames
    # record the wide prior variance which was used in fitting
    betaPriorVar <- rep(1e6, ncol(fit$modelMatrix))


    # store mu in case the user did not call estimateDispersionsGeneEst
    dimnames(fit$mu) <- NULL
    assay(objectNZ,"mu",withDimnames = FALSE) <- fit$mu
    assay(object,"mu",withDimnames = FALSE) <- .build_matrix_with_NA_rows(fit$mu, mcols(object)$allZero)

    # store the prior variance directly as an attribute
    # of the DESeqDataSet object, so it can be pulled later by
    # the results function (necessary for setting max Cook's distance)
    attr(object,"betaPrior") <- FALSE
    attr(object,"betaPriorVar") <- betaPriorVar
    attr(object,"modelMatrix") <- modelMatrix

    # add betas to the object
    modelMatrixNames <- colnames(modelMatrix)
    betaMatrix <- fit$betaMatrix
    colnames(betaMatrix) <- modelMatrixNames
    betaSE <- fit$betaSE
    colnames(betaSE) <- paste0("SE_",modelMatrixNames)
    betaConv <- fit$betaConv

    if (any(!betaConv)) {
        if (!quiet) message(paste(sum(!betaConv),"rows did not converge in beta, labelled in mcols(object)$betaConv. Use larger maxit argument"))
    }


    resultsList <- c(.matrix_to_list(betaMatrix),
                     .matrix_to_list(betaSE),
                     list(betaConv = betaConv,
                          betaIter = fit$betaIter,
                          deviance = -2 * fit$logLike))

    Results <- .build_DataFrame_with_NA_rows(resultsList, mcols(object)$allZero)

    modelMatrixNamesSpaces <- gsub("_"," ",modelMatrixNames)

    lfcType <- "MLE"
    coefInfo <- paste(paste0("log2 fold change (",lfcType,"):"),modelMatrixNamesSpaces)
    seInfo <- paste("standard error:",modelMatrixNamesSpaces)

    mcols(Results) <- DataFrame(type = rep("results",ncol(Results)),
                                description = c(coefInfo, seInfo,
                                                "convergence of betas",
                                                "iterations for betas",
                                                "deviance for the fitted model"))

    mcols(object) <- cbind(mcols(object),Results)
    return(object)
}




# Unexported, low-level function for fitting negative binomial GLMs
#
# Users typically call \code{\link{nbinomWaldTest}} or \code{\link{nbinomLRT}}
# which calls this function to perform fitting.  These functions return
# a \code{\link{DESeqDataSet}} object with the appropriate columns
# added.  This function returns results as a list.
#
# object a DESeqDataSet
# modelMatrix the design matrix
# modelFormula a formula specifying how to construct the design matrix
# alpha_hat the dispersion parameter estimates
# lambda the 'ridge' term added for the penalized GLM on the log2 scale
# renameCols whether to give columns variable_B_vs_A style names
# betaTol control parameter: stop when the following is satisfied:
#   abs(dev - dev_old)/(abs(dev) + 0.1) < betaTol
# maxit control parameter: maximum number of iteration to allow for
#   convergence
# useOptim whether to use optim on rows which have not converged:
#   Fisher scoring is not ideal with multiple groups and sparse
#   count distributions
# useQR whether to use the QR decomposition on the design matrix X
# forceOptim whether to use optim on all rows
# warnNonposVar whether to warn about non positive variances,
#   for advanced users only running LRT without beta prior,
#   this might be desirable to be ignored.
#
# return a list of results, with coefficients and standard
# errors on the log2 scale
#' @importFrom stats model.matrix formula dnbinom
#' @importFrom S4Vectors mcols
#' @importFrom SummarizedExperiment colData assay
.fit_Nbinom_GLMs <- function(object,
                             modelMatrix=NULL,
                             modelFormula,
                             alpha_hat,
                             lambda,
                             renameCols = TRUE,
                             betaTol = 1e-8,
                             maxit = 100L,
                             useOptim = TRUE,
                             useQR = TRUE,
                             forceOptim = FALSE,
                             warnNonposVar = TRUE) {
    if (missing(modelFormula)) {
        modelFormula <- design(object)
    }
    if (is.null(modelMatrix)) {
        modelAsFormula <- TRUE
        modelMatrix <- model.matrix(modelFormula, data=colData(object))
    } else {
        modelAsFormula <- FALSE
    }

    stopifnot(all(colSums(abs(modelMatrix)) > 0))

    # rename columns, for use as columns in DataFrame
    # and to emphasize the reference level comparison
    modelMatrixNames <- colnames(modelMatrix)
    modelMatrixNames[modelMatrixNames == "(Intercept)"] <- "Intercept"
    modelMatrixNames <- make.names(modelMatrixNames)

    if (renameCols) {
        convertNames <- .rename_model_matrix_columns(colData(object),
                                                     modelFormula)
        convertNames <- convertNames[convertNames$from %in% modelMatrixNames,,drop=FALSE]
        modelMatrixNames[match(convertNames$from, modelMatrixNames)] <- convertNames$to
    }
    colnames(modelMatrix) <- modelMatrixNames

    normalizationFactors <- if (!is.null(normalizationFactors(object))) {
        normalizationFactors(object)
    } else {
        matrix(rep(sizeFactors(object),each=nrow(object)),
               ncol=ncol(object))
    }

    if (missing(alpha_hat)) {
        alpha_hat <- assay(object, XTAIL_DISPERSION_ASSAY)
    }

    if (nrow(alpha_hat) != nrow(object)) {
        stop("alpha_hat needs to be the same length as nrows(object)")
    }

    # set a wide prior for all coefficients
    if (missing(lambda)) {
        lambda <- rep(1e-6, ncol(modelMatrix))
    }

    # bypass the beta fitting if the model formula is only intercept and
    # the prior variance is large (1e6)
    # i.e., LRT with reduced ~ 1 and no beta prior
    justIntercept <- if (modelAsFormula) {
        modelFormula == formula(~ 1)
    } else {
        ncol(modelMatrix) == 1 & all(modelMatrix == 1)
    }
    if (justIntercept & all(lambda <= 1e-6)) {
        alpha <- alpha_hat
        betaConv <- rep(TRUE, nrow(object))
        betaIter <- rep(1,nrow(object))
        betaMatrix <- matrix(log2(mcols(object)$baseMean),ncol=1)
        mu <- normalizationFactors * as.numeric(2^betaMatrix)
        logLike <- rowSums(dnbinom(counts(object), mu=mu, size=1/alpha, log=TRUE))
        deviance <- -2 * logLike
        modelMatrix <- model.matrix(~ 1, colData(object))
        colnames(modelMatrix) <- modelMatrixNames <- "Intercept"
        w <- (mu^-1 + alpha)^-1
        xtwx <- rowSums(w)
        sigma <- xtwx^-1
        betaSE <- matrix(log2(exp(1)) * sqrt(sigma),ncol=1)
        hat_diagonals <- w * xtwx^-1;
        res <- list(logLike = logLike, betaConv = betaConv, betaMatrix = betaMatrix,
                    betaSE = betaSE, mu = mu, betaIter = betaIter,
                    deviance = deviance,
                    modelMatrix=modelMatrix,
                    nterms=1, hat_diagonals=hat_diagonals)
        return(res)
    }

    qrx <- qr(modelMatrix)
    # if full rank, estimate initial betas for IRLS below
    if (qrx$rank == ncol(modelMatrix)) {
        Q <- qr.Q(qrx)
        R <- qr.R(qrx)
        y <- t(log(counts(object,normalized=TRUE) + .1))
        beta_mat <- t(solve(R, t(Q) %*% y))
    } else {
        if ("Intercept" %in% modelMatrixNames) {
            beta_mat <- matrix(0, ncol=ncol(modelMatrix), nrow=nrow(object))
            # use the natural log as fitBeta occurs in the natural log scale
            logBaseMean <- log(rowMeans(counts(object,normalized=TRUE)))
            beta_mat[,which(modelMatrixNames == "Intercept")] <- logBaseMean
        } else {
            beta_mat <- matrix(1, ncol=ncol(modelMatrix), nrow=nrow(object))
        }
    }

    # here we convert from the log2 scale of the betas
    # and the beta prior variance to the log scale
    # used in fitBeta.
    # so we divide by the square of the
    # conversion factor, log(2)
    lambdaLogScale <- lambda / log(2)^2

    betaRes <- .fit_Beta(ySEXP = counts(object),
                         xSEXP = modelMatrix,
                         nfSEXP = normalizationFactors,
                         alpha_hatSEXP = alpha_hat,
                         beta_matSEXP = beta_mat,
                         lambdaSEXP = lambdaLogScale,
                         tolSEXP = betaTol,
                         maxitSEXP = maxit,
                         useQRSEXP = useQR)
    mu <- normalizationFactors * t(exp(modelMatrix %*% t(betaRes$beta_mat)))
    dispersionMatrix <- assay(object, XTAIL_DISPERSION_ASSAY)
    logLike <- .get_nbinom_log_like(counts(object),
                                    mu,
                                    assay(object, XTAIL_DISPERSION_ASSAY))

    # test for stability
    rowStable <- apply(betaRes$beta_mat,1,function(row) sum(is.na(row))) == 0

    # test for positive variances
    rowVarPositive <- apply(betaRes$beta_var_mat,1,function(row) sum(row <= 0)) == 0

    # test for convergence, stability and positive variances
    betaConv <- betaRes$iter < maxit

    # here we transform the betaMatrix and betaSE to a log2 scale
    betaMatrix <- log2(exp(1))*betaRes$beta_mat
    colnames(betaMatrix) <- modelMatrixNames
    colnames(modelMatrix) <- modelMatrixNames
    # warn below regarding these rows with negative variance
    betaSE <- log2(exp(1))*sqrt(pmax(betaRes$beta_var_mat,0))
    colnames(betaSE) <- paste0("SE_",modelMatrixNames)

    # switch based on whether we should also use optim
    # on rows which did not converge
    rowsForOptim <- if (useOptim) {
        which(!betaConv | !rowStable | !rowVarPositive)
    } else {
        which(!rowStable | !rowVarPositive)
    }

    if (forceOptim) {
        rowsForOptim <- seq_along(betaConv)
    }

    if (length(rowsForOptim) > 0) {
        # we use optim if didn't reach convergence with the IRLS code
        resOptim <- .fit_Nbinom_GLMs_Optim(object,
                                           modelMatrix,
                                           lambda,
                                           rowsForOptim,
                                           rowStable,
                                           normalizationFactors,
                                           alpha_hat,
                                           betaMatrix,
                                           betaSE,
                                           betaConv,
                                           beta_mat,
                                           mu,
                                           logLike)
        betaMatrix <- resOptim$betaMatrix
        betaSE <- resOptim$betaSE
        betaConv <- resOptim$betaConv
        mu <- resOptim$mu
        logLike <- resOptim$logLike
    }

    stopifnot(!any(is.na(betaSE)))
    nNonposVar <- sum(rowSums(betaSE == 0) > 0)
    if (warnNonposVar & nNonposVar > 0) warning(nNonposVar,"rows had non-positive estimates of variance for coefficients")

    list(logLike = logLike, betaConv = betaConv, betaMatrix = betaMatrix,
         betaSE = betaSE, mu = mu, betaIter = betaRes$iter,
         deviance = betaRes$deviance,
         modelMatrix=modelMatrix,
         nterms=ncol(modelMatrix), hat_diagonals=betaRes$hat_diagonals)
}



# breaking out the optim backup code from fitNbinomGLMs
#' @importFrom stats dnbinom dnorm optim
.fit_Nbinom_GLMs_Optim <- function(object,
                                   modelMatrix,
                                   lambda,
                                   rowsForOptim,
                                   rowStable,
                                   normalizationFactors,
                                   alpha_hat,
                                   betaMatrix,
                                   betaSE,
                                   betaConv,
                                   beta_mat,
                                   mu,
                                   logLike) {
    scaleCols <- apply(modelMatrix,2,function(z) max(abs(z)))
    stopifnot(all(scaleCols > 0))
    x <- sweep(modelMatrix,2,scaleCols,"/")
    lambdaColScale <- lambda / scaleCols^2
    lambdaColScale <- ifelse(lambdaColScale == 0, 1e-6, lambdaColScale)
    lambdaLogScale <- lambda / log(2)^2
    lambdaLogScaleColScale <- lambdaLogScale / scaleCols^2
    large <- 30
    for (row in rowsForOptim) {
        betaRow <- if (rowStable[row] & all(abs(betaMatrix[row,]) < large)) {
            betaMatrix[row,] * scaleCols
        } else {
            beta_mat[row,] * scaleCols
        }
        nf <- normalizationFactors[row,]
        k <- counts(object)[row,]
        alpha <- alpha_hat[row]
        objectiveFn <- function(p) {
            mu_row <- as.numeric(nf * 2^(x %*% p))
            logLike <- sum(dnbinom(k,mu=mu_row,size=1/alpha,log=TRUE))
            logPrior <- sum(dnorm(p,0,sqrt(1/lambdaColScale),log=TRUE))
            negLogPost <- -1 * (logLike + logPrior)
            if (is.finite(negLogPost)) negLogPost else 10^300
        }
        o <- optim(betaRow, objectiveFn, method="L-BFGS-B",lower=-large, upper=large)
        ridge <- if (length(lambdaLogScale) > 1) {
            diag(lambdaLogScaleColScale)
        } else {
            as.matrix(lambdaLogScaleColScale,ncol=1)
        }
        # if we converged, change betaConv to TRUE
        if (o$convergence == 0) {
            betaConv[row] <- TRUE
        }
        # with or without convergence, store the estimate from optim
        betaMatrix[row,] <- o$par / scaleCols
        # calculate the standard errors
        mu_row <- as.numeric(nf * 2^(x %*% o$par))
        w <- diag((mu_row^-1 + alpha)^-1)
        xtwx <- t(x) %*% w %*% x
        xtwxRidgeInv <- solve(xtwx + ridge)
        sigma <- xtwxRidgeInv %*% xtwx %*% xtwxRidgeInv
        # warn below regarding these rows with negative variance
        betaSE[row,] <- log2(exp(1)) * sqrt(pmax(diag(sigma),0)) / scaleCols
        # store the new mu vector
        mu[row,] <- mu_row
        logLike[row] <- sum(dnbinom(k, mu=mu_row, size=1/alpha, log=TRUE))
    }
    return(list(betaMatrix=betaMatrix,betaSE=betaSE,
                betaConv=betaConv,
                mu=mu,logLike=logLike))
}

###

# Get base means and variances
#
# An internally used function to calculate the row means and variances
# from the normalized counts, which requires that \code{\link{estimateSizeFactors}}
# has already been called.  Adds these and a logical column if the row sums
# are zero to the mcols of the object.
#
# object a DESeqDataSet object
#
# return a DESeqDataSet object with columns baseMean
# and baseVar in the row metadata columns
#' @importFrom matrixStats rowVars
#' @importFrom S4Vectors mcols mcols<-
.get_base_means_and_variances <- function(object) {
    meanVarZero <- DataFrame(baseMean = unname(rowMeans(counts(object,normalized=TRUE))),
                             baseVar = unname(rowVars(counts(object,normalized=TRUE))),
                             allZero = unname(rowSums(counts(object)) == 0))
    mcols(meanVarZero) <- DataFrame(type = rep("intermediate",ncol(meanVarZero)),
                                    description = c("mean of normalized counts for all samples",
                                                    "variance of normalized counts for all samples",
                                                    "all counts for a gene are zero"))
    if (all(c("baseMean","baseVar","allZero") %in% names(mcols(object)))) {
        mcols(object)[c("baseMean","baseVar","allZero")] <- meanVarZero
    } else {
        mcols(object) <- cbind(mcols(object),meanVarZero)
    }
    return(object)
}






# convenience function for testing the log likelihood
# for a count matrix, mu matrix and vector disp
#' @importFrom stats dnbinom
.get_nbinom_log_like <- function(counts, mu, disp) {
    nbd <- dnbinom(counts,
                   mu = mu,
                   size = 1/disp,
                   log = TRUE)
    mat <- matrix(nbd, ncol = ncol(counts))
    rowSums(mat)
}

#' @importFrom S4Vectors mcols mcols<-
.sanitize_rowData <- function(object) {
    mc <- mcols(mcols(object))
    if (is.null(mc)) {
        mc <- DataFrame(type = rep("input",ncol(mcols(object))),
                        description = character(ncol(mcols(object))))
    } else {
        mc$type <- as.character(mc$type)
        mc$description <- as.character(mc$description)
        mc$type[is.na(mc$type)] <- ""
        mc$description[is.na(mc$description)] <- ""
    }
    mcols(mcols(object)) <- mc
    object
}


# convenience function for building larger matrices
# by filling in NA rows
.build_matrix_with_NA_rows <- function(m, NARows) {
    mFull <- matrix(NA, ncol=ncol(m), nrow=length(NARows))
    mFull[!NARows,] <- m
    mFull
}

# convenience function for building results tables
# out of a list and filling in NA rows
.build_DataFrame_with_NA_rows <- function(resultsList, NArows) {
    lengths <- vapply(resultsList,length,integer(1))
    if (!all(lengths == lengths[1])) {
        stop("lengths of vectors in resultsList must be equal")
    }
    if (sum(!NArows) != lengths[1]) {
        stop("number of non-NA rows must be equal to lengths of vectors in resultsList")
    }
    if (sum(NArows) == 0) {
        return(DataFrame(resultsList))
    }
    dfFull <- DataFrame(lapply(resultsList, function(x) vector(mode(x), length(NArows))))
    dfFull[NArows,] <- NA
    dfFull[!NArows,] <- DataFrame(resultsList)
    dfFull
}


# convenience function for breaking up matrices
# by column and preserving column names
.matrix_to_list <- function(m) {
    l <- split(m, col(m))
    names(l) <- colnames(m)
    l
}

# convenience function to make more descriptive names
# for factor variables
.rename_model_matrix_columns <- function(data, design) {
    data <- as.data.frame(data)
    designVars <- all.vars(design)
    designVarsClass <- vapply(designVars, function(v) class(data[[v]]),
                              character(1))
    factorVars <- designVars[designVarsClass == "factor"]
    colNamesFrom <- make.names(do.call(c,lapply(factorVars, function(v) paste0(v,levels(data[[v]])[-1]))))
    colNamesTo <- make.names(do.call(c,lapply(factorVars, function(v) paste0(v,"_",levels(data[[v]])[-1],"_vs_",levels(data[[v]])[1]))))
    data.frame(from=colNamesFrom,to=colNamesTo,stringsAsFactors=FALSE)
}
