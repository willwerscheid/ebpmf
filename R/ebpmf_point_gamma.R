#' @title Empirical Bayes Poisson Matrix Factorization with Prior Family Mixture of Exponential
#' @description Uses Empirical Bayes to fit the model \deqn{X_{ij}  ~ Poi(\sum_k L_{ik} F_{jk})} with \deqn{L_{.k} ~ g_k()}, where dim(X) = c(n,p); dim(L) = c(n,K); dim(F) = c(p,K)
#' with g_k being either Mixture of Exponential, or Point Gamma
#' @import mixsqp
#' @import ebpm
#' @import gtools
#' @import NNLM

#' @details The model is fit in 2 stages: i) estimate \eqn{g} by maximum likelihood (over pi_k)
#' ii) Compute posterior distributions for \eqn{\lambda_j} given \eqn{x_j,\hat{g}}.
#' @param X count matrix (dim(X) = c(n, p)).
#' @param K number of topics
#' @param  maxiter.out  maximum iterations in the outer  loop
#' @param  maxiter.int  maximum iterations in the inner loop
#' @param verbose T if print ELBO
#' @param seed random seed
#'
#'
#' @return A list containing elements (this is freeuqntly updated):
#'     \describe{
#'       \item{\code{qls_mean}}{A n by k matrix: Approximate posterior mean for L}
#'       \item{\code{qls_mean_log}}{A n by k matrix: Approximate posterior log mean for L}
#'       \item{\code{gls}}{A list of K elements, each element is the estimated prior for the kth column of L}
#'       \item{\code{qfs_mean}}{A p by k matrix: Approximate posterior mean for F}
#'       \item{\code{qfs_mean_log}}{A p by k matrix: Approximate posterior log mean for F}
#'       \item{\code{gfs}}{A list of K elements, each element is the estimated prior for the kth column of F}
#'      }
#'
#'
#' @examples
#' To add

#'
#' @export ebpmf_point_gamma
#'
#'
ebpmf_point_gamma <- function(X, K, maxiter.out = 10, fix_g = F, verbose = F, seed = 123){
  set.seed(seed)
  ## init from NNLM::nnmf result
  start = proc.time()
  qg = initialize_qg(X, K)
  runtime_init = (proc.time() - start)[[3]]

  runtime_rank1 = 0
  runtime_ez = 0
  ELBOs = c()
  KLs = c()
  lls = c()

  start = proc.time()
  tmp = get_Ez(X, qg, K)
  Ez = tmp$Ez
  zeta = tmp$zeta
  rm(tmp)
  runtime_ez = runtime_ez + (proc.time() - start)[[3]]

  for(iter in 1:maxiter.out){
    KL = 0
    for(k in 1:K){
      ## update q, g
      start = proc.time()
      init_l  = list(mean = qg$qls_mean[,k])
      if(is.null(qg$gls[[k]])){
        tmp = ebpmf_rank1_point_gamma_helper(X = Ez[,,k],init = init_l)
      }else{
        if(fix_g){
          tmp = ebpmf_rank1_point_gamma_helper(X = Ez[,,k],init = init_l,
                                               gl_init = qg$gls[[k]], gf_init = qg$gfs[[k]], fix_gl = T, fix_gf = T)
        }else{
          tmp = ebpmf_rank1_point_gamma_helper(X = Ez[,,k],init = init_l, gl_init = qg$gls[[k]], gf_init = qg$gfs[[k]])
        }
      }
      KL = KL + tmp$kl_l + tmp$kl_f
      qg = update_qg(tmp, qg, k)
      ## update Z
      start = proc.time()
      tmp = get_Ez(X, qg, K)
      Ez = tmp$Ez
      zeta = tmp$zeta
      rm(tmp)
      runtime_ez = runtime_ez + (proc.time() - start)[[3]]
    }
    ll = compute_ll(X, qg)
    ELBO = ll - KL
    KLs <- c(KLs, KL)
    ELBOs <- c(ELBOs, ELBO)
    lls <- c(lls, ll)
    if(verbose){
      print("iter         ELBO")
      print(sprintf("%d:    %f", iter, ELBO))
    }
  }
  # print("summary of  runtime:")
  # print(sprintf("init           : %f", runtime_init))
  # print(sprintf("Ez     per time: %f", runtime_ez/(iter*K)))
  # print(sprintf("rank1  per time: %f", runtime_rank1/(iter*K)))
  return(list(qg = qg, ELBO = ELBOs, KL = KLs, ll = lls))
}


## ================== helper functions ==================================
#' @export  ebpmf_rank1_point_gamma_helper
ebpmf_rank1_point_gamma_helper <- function(X, init = NULL,gl_init = NULL, gf_init = NULL, fix_gl = F,fix_gf = F,maxiter = 1, seed = 123, verbose = F){
  set.seed(seed)
  X_rowsum = rowSums(X)
  X_colsum = colSums(X)
  p = length(X_colsum)
  n = length(X_rowsum)

  if(verbose){
    print(sprintf("%2s   %10s  %10s   %10s   %10s   %10s", "iter", "elbo", "kl_l", "kl_f", "sum_El", "sum_Ef"))
  }

  ## initialization.  It doesn't matter when doing rank-1 case. Maybe useful for rank-k case  when we assess convergence.
  if(is.null(init)){
    nnmf_res = NNLM::nnmf(A = X, k = 1, loss = "mkl", method = "lee", max.iter = 1)
    ql =  list(mean = nnmf_res$W[,1])
  }else{ql = init}

  #browser()
  for(i in 1:maxiter){
    ## update q(f), g(f)
    sum_El = sum(ql$mean)
    if(is.null(gf_init)){
      tmp_f = ebpm::ebpm_point_gamma(x = X_colsum, s = replicate(p,sum_El))
    }else{
      tmp_f = ebpm::ebpm_point_gamma(x = X_colsum, s = replicate(p,sum_El), g_init = gf_init, fix_g = fix_gf)
    }
    qf = tmp_f$posterior
    gf = tmp_f$fitted_g
    ll_f = tmp_f$log_likelihood
    ### compute KL(q(f) || g(f)) = -Eq log(g(f)/q(f))
    kl_f = compute_kl(X_colsum, replicate(p,sum_El), tmp_f)
    ## update q(l), g(l)
    sum_Ef = sum(qf$mean)
    #browser()
    if(is.null(gl_init)){
      tmp_l = ebpm_point_gamma(x = X_rowsum, s = replicate(n,sum_Ef))
    }else{
      tmp_l = ebpm_point_gamma(x = X_rowsum, s = replicate(n,sum_Ef), g_init = gl_init, fix_g = fix_gl)
    }
    ql = tmp_l$posterior
    gl = tmp_l$fitted_g
    ll_l = tmp_l$log_likelihood
    ### compute KL(q(l) || g(l)) = -Eq log(g(l)/q(l))
    kl_l = compute_kl(X_rowsum, replicate(n,sum_Ef), tmp_l)

    if(verbose){
      ## compute ELBO (for debugging)
      tmp = X * outer(ql$mean_log, qf$mean_log, "+")
      tmp[X == 0] = 0
      ll = - outer(ql$mean,  qf$mean, "*") + tmp
      ll = sum(ll)
      elbo = ll - kl_l - kl_f
      print(sprintf("%3d   %.10f  %.10f   %.10f   %.10f   %.10f", i, elbo, kl_l, kl_f, sum_El, sum_Ef))
    }

    qg = list(ql = ql, gl = gl, kl_l = kl_l, qf = qf, gf = gf, kl_f = kl_f)
  }
  return(qg)
}









