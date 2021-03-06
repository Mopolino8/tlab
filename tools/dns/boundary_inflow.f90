#include "types.h"
#include "dns_error.h"
#include "dns_const.h"
#include "dns_const_mpi.h"

!########################################################################
!# DESCRIPTION
!#
!# Calculating RHS forcings at the inflow plane in spatially evolving cases
!#
!########################################################################
MODULE BOUNDARY_INFLOW

  USE DNS_TYPES,     ONLY : filter_dt, grid_dt
  USE DNS_CONSTANTS, ONLY : efile, lfile
#ifdef TRACE_ON 
  USE DNS_CONSTANTS, ONLY : tfile 
#endif 
  USE DNS_GLOBAL,    ONLY : imax,jmax,kmax, inb_flow, inb_scal, inb_scal_array, icalc_flow,icalc_scal
  USE DNS_GLOBAL,    ONLY : imode_eqns, imode_flow, itransport
  USE DNS_GLOBAL,    ONLY : g, qbg, epbackground, pbackground
  USE DNS_GLOBAL,    ONLY : rtime,itime
  USE DNS_GLOBAL,    ONLY : visc,damkohler
  USE THERMO_GLOBAL, ONLY : imixture

#ifdef USE_MPI
  USE DNS_MPI
#endif

  IMPLICIT NONE
  SAVE
  
  TINTEGER, PARAMETER :: MAX_FRC_FREC   = 32

  TYPE(grid_dt), DIMENSION(3) :: g_inf

  TINTEGER :: ifrc_mode, ifrc_ifield
  TREAL    :: frc_length, frc_adapt

  TYPE(filter_dt), DIMENSION(3) :: FilterInflow
  TINTEGER :: FilterInflowStep

! Discrete forcing
  TINTEGER :: ifrcdsc_mode
  TREAL    :: frc_delta
  
  TINTEGER :: nx2d, nx3d, nz3d
  TREAL    :: A2D(MAX_FRC_FREC), Phix2d(MAX_FRC_FREC)
  TREAL    :: A3D(MAX_FRC_FREC), Phix3d(MAX_FRC_FREC), Phiz3d(MAX_FRC_FREC)

CONTAINS
!########################################################################
!########################################################################
!# Initializing inflow fields for broadband forcing case.
SUBROUTINE BOUNDARY_INFLOW_INITIALIZE(etime, q_inf,s_inf, txc, wrk2d,wrk3d)

  IMPLICIT NONE
  
#include "integers.h"
  
  TREAL etime
  TREAL, DIMENSION(g_inf(1)%size*&
                   g_inf(2)%size*&
                   g_inf(3)%size,inb_flow), INTENT(INOUT) :: q_inf
  TREAL, DIMENSION(g_inf(1)%size*&
                   g_inf(2)%size*&
                   g_inf(3)%size,inb_scal), INTENT(INOUT) :: s_inf
  TREAL, DIMENSION(g_inf(1)%size*&
                   g_inf(2)%size*&
                   g_inf(3)%size),          INTENT(INOUT) :: txc, wrk3d
  TREAL, DIMENSION(*),                      INTENT(INOUT) :: wrk2d

  TARGET :: q_inf

! -------------------------------------------------------------------
  TINTEGER is, itimetmp, bcs(2,1)
  TINTEGER joffset, jglobal, j, iwrk_size
  TREAL tolerance, dy
  TREAL visctmp, rtimetmp
  CHARACTER*32 fname, sname, str
  CHARACTER*128 line

#ifdef USE_MPI
  TINTEGER isize_loc,id
#endif

! Pointers to existing allocated space
  TREAL, DIMENSION(:), POINTER :: p_inf, rho_inf

! ###################################################################
#ifdef TRACE_ON
  CALL IO_WRITE_ASCII(tfile, 'ENTERING BOUNDARY_INFLOW_INIT')
#endif

#ifdef USE_MPI
! I/O routines not yet developed for this particular case
  IF ( ims_npro_i .GT. 1 ) THEN
     CALL IO_WRITE_ASCII(efile,'BOUNDARY_INIT. I/O routines undeveloped.')
     CALL DNS_STOP(DNS_ERROR_UNDEVELOP)     
  ENDIF
#endif

! #######################################################################
! Definining types for parallel mode
! #######################################################################
#ifdef USE_MPI
  IF ( FilterInflow(1)%type .NE. DNS_FILTER_NONE ) THEN !  Required for inflow explicit filter
     CALL IO_WRITE_ASCII(lfile,'Initialize MPI types for inflow filter.')
     id    = DNS_MPI_K_INFLOW
     isize_loc = FilterInflow(1)%size *FilterInflow(2)%size
     CALL DNS_MPI_TYPE_K(ims_npro_k, kmax, isize_loc, i1, i1, i1, i1, &
          ims_size_k(id), ims_ds_k(1,id), ims_dr_k(1,id), ims_ts_k(1,id), ims_tr_k(1,id))
     FilterInflow(3)%mpitype = id
  ENDIF
#endif

! Define pointers
  p_inf   => q_inf(:,4)
  rho_inf => q_inf(:,5)

  iwrk_size = g_inf(1)%size *g_inf(2)%size *kmax
  IF ( imax*jmax*kmax .LT. iwrk_size ) THEN
     CALL IO_WRITE_ASCII(efile,'BOUNDARY_INFLOW_INIT. Not enough space in array txc.')
     CALL DNS_STOP(DNS_ERROR_WRKSIZE)
  ENDIF

! ###################################################################
  IF ( ifrc_mode .EQ. 2 .OR. ifrc_mode .EQ. 3 .OR. ifrc_mode .EQ. 4 ) THEN

! Checking the matching; we could move this outside... 
     tolerance = C_1EM10_R
     joffset = ( jmax - g_inf(2)%size )/2
     DO j = 1,g_inf(2)%size
        jglobal = joffset + j
        dy = ABS( g(2)%nodes(jglobal) -g_inf(2)%nodes(j) )
        IF (dy.gt.tolerance) THEN
           CALL IO_WRITE_ASCII(efile, 'BOUNDARY_INFLOW. Inflow domain does not match.')
           CALL DNS_STOP(DNS_ERROR_INFLOWDOMAIN)
        ENDIF
     ENDDO

! Reading fields
     fname = 'flow.inf'
     sname = 'scal.inf'
     ifrc_ifield = INT( qbg(1)%mean *etime /g_inf(1)%scale ) + 1
     IF ( ifrc_mode .EQ. 3 ) THEN
        WRITE(str,*) ifrc_ifield
        fname = TRIM(ADJUSTL(fname))//TRIM(ADJUSTL(str))
        sname = TRIM(ADJUSTL(sname))//TRIM(ADJUSTL(str))
        line='Reading InflowFile '//TRIM(ADJUSTL(str))
        CALL IO_WRITE_ASCII(lfile,line)
     ENDIF

     rtimetmp = rtime
     itimetmp = itime
     visctmp  = visc
     CALL DNS_READ_FIELDS(fname, i2, g_inf(1)%size,g_inf(2)%size,kmax, inb_flow, i0, iwrk_size, q_inf, wrk3d)
     CALL DNS_READ_FIELDS(sname, i1, g_inf(1)%size,g_inf(2)%size,kmax, inb_scal, i0, iwrk_size, s_inf, wrk3d)
     rtime = rtimetmp
     itime = itimetmp
     visc  = visctmp

! array p contains the internal energy. Now we put in the pressure 
     CALL THERMO_CALORIC_TEMPERATURE&
          (g_inf(1)%size, g_inf(2)%size, kmax, s_inf, p_inf, rho_inf, txc, wrk3d)
     CALL THERMO_THERMAL_PRESSURE&
          (g_inf(1)%size, g_inf(2)%size, kmax, s_inf, rho_inf, txc, p_inf)

! ###################################################################
! Performing the derivatives
! 
! Note that a field f_0(x) is convected with a velocity U along OX, i.e.
! f(x,t) = f_0(x-Ut), and therefore \partial f/\partial t = -U df_0/dx.
! ###################################################################
     bcs = 0
     
     IF ( icalc_flow .EQ. 1 ) THEN
        DO is = 1, inb_flow
           CALL OPR_PARTIAL_X(OPR_P1, g_inf(1)%size,g_inf(2)%size,kmax, bcs, g_inf(1), q_inf(1,is), txc, wrk3d, wrk2d, wrk3d)
           q_inf(:,is) = -txc(:) *qbg(1)%mean
        ENDDO
     ENDIF
     
     IF ( icalc_scal .EQ. 1 ) THEN
        DO is = 1,inb_scal
           CALL OPR_PARTIAL_X(OPR_P1, g_inf(1)%size,g_inf(2)%size,kmax, bcs, g_inf(1), s_inf(1,is), txc, wrk3d, wrk2d, wrk3d)
           s_inf(:,is) = -txc(:) *qbg(1)%mean
        ENDDO
     ENDIF

  ENDIF

#ifdef TRACE_ON
  CALL IO_WRITE_ASCII(tfile, 'LEAVING BOUNDARY_INFLOW_INIT')
#endif

  RETURN
END SUBROUTINE BOUNDARY_INFLOW_INITIALIZE

!########################################################################
!########################################################################
! Broadband
SUBROUTINE BOUNDARY_INFLOW_BROADBAND(etime, inf_rhs, q_inf,s_inf, txc, wrk2d,wrk3d)
  
  IMPLICIT NONE
  
  TREAL etime
  TREAL, DIMENSION(jmax,kmax,inb_flow+inb_scal), INTENT(OUT)   :: inf_rhs
  TREAL, DIMENSION(g_inf(1)%size,&
                   g_inf(2)%size,&
                   g_inf(3)%size,inb_flow),      INTENT(INOUT) :: q_inf
  TREAL, DIMENSION(g_inf(1)%size,&
                   g_inf(2)%size,&
                   g_inf(3)%size,inb_scal),      INTENT(INOUT) :: s_inf
  TREAL, DIMENSION(g_inf(1)%size*&
                   g_inf(2)%size*&
                   g_inf(3)%size),               INTENT(INOUT) :: txc, wrk3d
  TREAL, DIMENSION(*),                           INTENT(INOUT) :: wrk2d

  TARGET :: q_inf

! -------------------------------------------------------------------
  TREAL xaux, dx_loc, vmult
  TINTEGER joffset, jglobal, ileft, iright, j, k, is, ip
  TREAL BSPLINES3P, BSPLINES3

! ###################################################################
#ifdef TRACE_ON
  CALL IO_WRITE_ASCII(tfile, 'ENTERING BOUNDARY_INFLOW_BROADBAND' )
#endif

! Transient factor
  IF ( frc_adapt .GT. C_0_R .AND. etime .LE. frc_adapt ) THEN
     vmult = etime / frc_adapt
  ELSE
     vmult = C_1_R
  ENDIF

! check if we need to read again inflow data
  IF ( ifrc_mode .EQ. 3 .AND. INT(qbg(1)%mean*etime/g_inf(1)%scale)+1 .NE. ifrc_ifield ) THEN
     CALL BOUNDARY_INFLOW_INITIALIZE(etime, q_inf,s_inf, txc, wrk2d,wrk3d)
  ENDIF

! ###################################################################
! Getting the position
! ###################################################################
  joffset = (jmax-g_inf(2)%size)/2

  xaux = qbg(1)%mean*etime
! Remove integral length scales of box
  xaux = xaux - INT(xaux/g_inf(1)%scale)*g_inf(1)%scale
! Set distance from box initial length
  xaux = g_inf(1)%scale-xaux

  dx_loc = g_inf(1)%nodes(2) - g_inf(1)%nodes(1)
! Get left index
  ileft = INT(xaux/dx_loc) +1
! Check bounds
  IF ( ileft .GT. g_inf(1)%size ) THEN
     ileft = 1
  ENDIF
! Set right index
  iright = ileft + 1
! Check bounds
  IF ( iright .GT. g_inf(1)%size ) THEN
     iright = 1
  ENDIF
! Get relative distance from left point
  xaux = (xaux-(g_inf(1)%nodes(ileft)-g_inf(1)%nodes(1)))/dx_loc

! ###################################################################
! Sampling the information
! ###################################################################
! -------------------------------------------------------------------
! Periodic
! -------------------------------------------------------------------
  IF ( ifrc_mode .EQ. 2 ) THEN
     DO k = 1,kmax
        DO j = 1,g_inf(2)%size
           jglobal = joffset + j
           DO is = 1,inb_scal
              inf_rhs(jglobal,k,is) = inf_rhs(jglobal,k,is) + vmult *BSPLINES3P(q_inf(1,j,k,is), g_inf(1)%size, ileft, xaux)
           ENDDO

           IF ( icalc_scal .EQ. 1 ) THEN
              DO is = 1,inb_scal
                 ip = inb_flow +is
                 inf_rhs(jglobal,k,ip) = inf_rhs(jglobal,k,ip) + vmult *BSPLINES3P(s_inf(1,j,k,is), g_inf(1)%size, ileft, xaux)
              ENDDO
           ENDIF
           
        ENDDO
     ENDDO
    
! -------------------------------------------------------------------
! Sequential
! -------------------------------------------------------------------
  ELSE
     DO k = 1,kmax
        DO j = 1,g_inf(2)%size
           jglobal = joffset + j
           DO is = 1,inb_flow
              inf_rhs(jglobal,k,is) = inf_rhs(jglobal,k,is) + vmult *BSPLINES3(q_inf(1,j,k,is), g_inf(1)%size, ileft, xaux)
           ENDDO
           
           IF ( icalc_scal .EQ. 1 ) THEN
              DO is = 1,inb_scal
                 ip = inb_flow +is
                 inf_rhs(jglobal,k,ip) = inf_rhs(jglobal,k,ip) + vmult *BSPLINES3(s_inf(1,j,k,is), g_inf(1)%size, ileft, xaux)
              ENDDO
           ENDIF

        ENDDO
     ENDDO
           
  ENDIF

! ###################################################################
! Filling the rest
! ###################################################################
  DO j = 1,joffset
     inf_rhs(j,:,:) = inf_rhs(j,:,:) + C_0_R
  ENDDO
  DO j = jmax-joffset+1,jmax
     inf_rhs(j,:,:) = inf_rhs(j,:,:) + C_0_R
  ENDDO

#ifdef TRACE_ON
  CALL IO_WRITE_ASCII(tfile, 'LEAVING BOUNDARY_INFLOW_BROADBAND' )
#endif
  RETURN
END SUBROUTINE BOUNDARY_INFLOW_BROADBAND

!########################################################################
!########################################################################
! Discrete

SUBROUTINE BOUNDARY_INFLOW_DISCRETE(etime, inf_rhs)
  
  IMPLICIT NONE

  TREAL etime
  TREAL inf_rhs(jmax,kmax,*)

! -------------------------------------------------------------------
  TINTEGER j, k, jsim, idsp
  TREAL ycenter, fy, fyp, wx, wz, wxloc, wzloc, xaux
  TREAL u2d, v2d, u3d, v3d, w3d, vmult
  TINTEGER inx2d, inx3d, inz3d

! ###################################################################
#ifdef TRACE_ON
  CALL IO_WRITE_ASCII(tfile, 'ENTERING BOUNDARY_INFLOW_DISCRETE' )
#endif

#ifdef USE_MPI
  idsp = ims_offset_k 
#else 
  idsp = 0
#endif

  wx = C_2_R * C_PI_R / frc_length
  wz = C_2_R * C_PI_R / g(3)%scale
  xaux =-qbg(1)%mean *etime

! Transient factor
  IF ( frc_adapt .GT. C_0_R .AND. etime .LE. frc_adapt ) THEN
     vmult = etime / frc_adapt
  ELSE
     vmult = C_1_R
  ENDIF

! ###################################################################
! Forcing for shear 
! ###################################################################
  IF ( imode_flow .EQ. DNS_FLOW_SHEAR ) THEN

     DO j = 1, jmax

        ycenter = g(2)%nodes(j) - g(2)%scale *qbg(1)%ymean - g(2)%nodes(1)
        fy  = EXP(-(ycenter/(C_2_R*frc_delta))**2)*frc_delta
        fyp =-ycenter*fy/(C_2_R * frc_delta**2)

        ! 2D perturbation

        DO inx2d = 1,nx2d

           wxloc = M_REAL(inx2d)*wx

           DO k = 1,kmax
              u2d = A2d(inx2d) * wxloc*        COS(wxloc*xaux+Phix2d(inx2d)) * fyp 
              v2d = A2d(inx2d) * wxloc*wxloc * SIN(wxloc*xaux+Phix2d(inx2d)) * fy
              inf_rhs(j,k,2) = inf_rhs(j,k,2) - vmult *qbg(1)%mean *u2d
              inf_rhs(j,k,3) = inf_rhs(j,k,3) - vmult *qbg(1)%mean *v2d
           ENDDO

        ENDDO

        ! 3D perturbation

        IF (kmax .GT. 1) THEN

           DO inx3d = 1, nx3d
              DO inz3d = 1, nz3d

                 wxloc = M_REAL(inx3d)*wx
                 wzloc = M_REAL(inz3d)*wz

                 DO k=1, kmax
                    u3d = A3d(inx3d)*wxloc*SIN(wxloc*xaux+Phix3d(inx3d)) * &
                         SIN(wzloc*g(3)%nodes(k)+Phiz3d(inz3d)) * fyp
                    v3d = A3d(inx3d)*wxloc*COS(wxloc*xaux+Phix3d(inx3d)) * &
                         SIN(wzloc*g(3)%nodes(k)+Phiz3d(inz3d)) * fy * &
                         (wxloc+wzloc)
                    w3d =-A3d(inx3d)*wxloc*SIN(wxloc*xaux+Phix3d(inx3d)) * &
                         COS(wzloc*g(3)%nodes(k)+Phiz3d(inz3d)) * fyp
                    inf_rhs(j,k,2) = inf_rhs(j,k,2) - vmult*qbg(1)%mean*u3d
                    inf_rhs(j,k,3) = inf_rhs(j,k,3) - vmult*qbg(1)%mean*v3d
                    inf_rhs(j,k,4) = inf_rhs(j,k,4) - vmult*qbg(1)%mean*w3d
                 ENDDO

              ENDDO
           ENDDO

        ENDIF

     ENDDO

! ###################################################################
! Forcing for jet
! ###################################################################
  ELSE IF ( imode_flow .EQ. DNS_FLOW_JET ) THEN

     DO j = 1,jmax/2

        jsim = jmax - j + 1

        ycenter = g(2)%nodes(j) - g(2)%scale *qbg(1)%ymean + qbg(1)%diam/C_2_R - g(2)%nodes(1)
        fy  = EXP(-(ycenter/(C_2_R*frc_delta))**2)*frc_delta
        fyp =-ycenter*fy/(C_2_R * frc_delta**2)

        ! 2D perturbation

        DO inx2d = 1,nx2d

           wxloc = M_REAL(inx2d)*wx

           DO k = 1,kmax
              u2d = A2d(inx2d) * wxloc *       COS(wxloc*xaux+Phix2d(inx2d)) *fyp 
              v2d = A2d(inx2d) * wxloc*wxloc * SIN(wxloc*xaux+Phix2d(inx2d)) *fy
              inf_rhs(j,k,2) = inf_rhs(j,k,2) - vmult*qbg(1)%mean*u2d
              inf_rhs(j,k,3) = inf_rhs(j,k,3) - vmult*qbg(1)%mean*v2d
              !          varicose
              IF (ifrcdsc_mode .EQ. 1) THEN
                 inf_rhs(jsim,k,2) = inf_rhs(jsim,k,2) - vmult*qbg(1)%mean*u2d
                 inf_rhs(jsim,k,3) = inf_rhs(jsim,k,3) + vmult*qbg(1)%mean*v2d
                 !          sinuous
              ELSE
                 inf_rhs(jsim,k,2) = inf_rhs(jsim,k,2) + vmult*qbg(1)%mean*u2d
                 inf_rhs(jsim,k,3) = inf_rhs(jsim,k,3) - vmult*qbg(1)%mean*v2d
              ENDIF

           ENDDO

        ENDDO

        ! 3D perturbation

        IF (kmax .GT. 1) THEN

           DO inx3d = 1, nx3d
              DO inz3d = 1, nz3d

                 wxloc = M_REAL(inx3d)*wx
                 wzloc = M_REAL(inz3d)*wz

                 DO k=1, kmax
                    u3d = A3d(inx3d)*wxloc*SIN(wxloc*xaux+Phix3d(inx3d)) * &
                         SIN(wzloc*g(3)%nodes(k)+Phiz3d(inz3d)) * fyp
                    v3d = A3d(inx3d)*wxloc*COS(wxloc*xaux+Phix3d(inx3d)) * &
                         SIN(wzloc*g(3)%nodes(k)+Phiz3d(inz3d)) * fy * &
                         (wxloc+wzloc)
                    w3d =-A3d(inx3d)*wxloc*SIN(wxloc*xaux+Phix3d(inx3d)) * &
                         COS(wzloc*g(3)%nodes(k)+Phiz3d(inz3d)) * fyp
                    inf_rhs(j,k,2) = inf_rhs(j,k,2) - vmult*qbg(1)%mean*u3d
                    inf_rhs(j,k,3) = inf_rhs(j,k,3) - vmult*qbg(1)%mean*v3d
                    inf_rhs(j,k,4) = inf_rhs(j,k,4) - vmult*qbg(1)%mean*w3d
                    !             varicose
                    IF (ifrcdsc_mode .EQ. 1) THEN
                       inf_rhs(jsim,k,2) = inf_rhs(jsim,k,2) - vmult*qbg(1)%mean*u3d
                       inf_rhs(jsim,k,3) = inf_rhs(jsim,k,3) + vmult*qbg(1)%mean*v3d
                       inf_rhs(jsim,k,4) = inf_rhs(jsim,k,4) - vmult*qbg(1)%mean*w3d
                       !             sinuous
                    ELSE
                       inf_rhs(jsim,k,2) = inf_rhs(jsim,k,2) + vmult*qbg(1)%mean*u3d
                       inf_rhs(jsim,k,3) = inf_rhs(jsim,k,3) - vmult*qbg(1)%mean*v3d
                       inf_rhs(jsim,k,4) = inf_rhs(jsim,k,4) + vmult*qbg(1)%mean*w3d
                    ENDIF

                 ENDDO

              ENDDO
           ENDDO

        ENDIF

     ENDDO

  ELSE 

  ENDIF

#ifdef TRACE_ON
  CALL IO_WRITE_ASCII(tfile, 'LEAVING BOUNDARY_INFLOW_DISCRETE' )
#endif

  RETURN
END SUBROUTINE BOUNDARY_INFLOW_DISCRETE

!########################################################################
!########################################################################
! Filter

SUBROUTINE BOUNDARY_INFLOW_FILTER(bcs_vi, bcs_vi_scal, q,s, txc, wrk1d,wrk2d,wrk3d)
  
  IMPLICIT NONE
  
#include "integers.h"
  
  TREAL, DIMENSION(imax,jmax,kmax,*), INTENT(INOUT) :: q,s
  TREAL, DIMENSION(jmax,kmax,*),      INTENT(IN)    :: bcs_vi, bcs_vi_scal
  TREAL, DIMENSION(imax*jmax*kmax,2), INTENT(INOUT) :: txc
  TREAL, DIMENSION(*),                INTENT(INOUT) :: wrk1d,wrk2d,wrk3d

  TARGET q
  
! -----------------------------------------------------------------------
  TINTEGER i,j,k,ip, iq, iq_loc(inb_flow), is
  TINTEGER j1, imx, jmx, ifltmx, jfltmx

! Pointers to existing allocated space
  TREAL, DIMENSION(:,:,:), POINTER :: e, rho, p, T, vis

! ###################################################################
! #######################################################################
  CALL IO_WRITE_ASCII(efile,'BOUNDARY_BUFFER_FILTER. Needs to be updated to new filter routines.')
  ! FilterInflow needs to be initiliazed
  CALL DNS_STOP(DNS_ERROR_UNDEVELOP)

! Define pointers
  IF ( imode_eqns .EQ. DNS_EQNS_TOTAL .OR. imode_eqns .EQ. DNS_EQNS_INTERNAL ) THEN
     e   => q(:,:,:,4)
     rho => q(:,:,:,5)
     p   => q(:,:,:,6)
     T   => q(:,:,:,7)
     
     IF ( itransport .EQ. EQNS_TRANS_SUTHERLAND .OR. itransport .EQ. EQNS_TRANS_POWERLAW ) vis => q(:,:,:,8)

  ENDIF

! Define counters
  imx = FilterInflow(1)%size
  j1  = ( jmax -FilterInflow(2)%size )/2 +1
  jmx = ( jmax +FilterInflow(2)%size )/2
  j1  = MIN(MAX(j1,i1),jmax)
  jmx = MIN(MAX(jmx,i1),jmax)

  ifltmx = imx-i1+1
  jfltmx = jmx-j1+1

  IF ( imode_eqns .EQ. DNS_EQNS_TOTAL .OR. imode_eqns .EQ. DNS_EQNS_INTERNAL ) THEN
     iq_loc = (/ 5,1,2,3,6 /) ! Filtered variables: rho, u,v,w, p
  ELSE
     iq_loc = (/ 1,2,3 /)
  ENDIF
  
! #######################################################################
  DO iq = 1,inb_flow
     
! -----------------------------------------------------------------------
! Remove mean field
! -----------------------------------------------------------------------
     ip = 1
     DO k = 1,kmax
        DO j = j1,jmx
           DO i = i1,imx
              wrk3d(ip) = q(i,j,k,iq_loc(iq)) - bcs_vi(j,k,iq_loc(iq))
              ip = ip + 1
           ENDDO
        ENDDO
     ENDDO
     
! -----------------------------------------------------------------------
     CALL OPR_FILTER(ifltmx,jfltmx,kmax, FilterInflow, wrk3d, wrk1d,wrk2d,txc)
     
! -----------------------------------------------------------------------
! Add mean field
! -----------------------------------------------------------------------
     ip = 1
     DO k = 1,kmax
        DO j = j1,jmx
           DO i = i1,imx
              q(i,j,k,iq_loc(iq))=  wrk3d(ip) + bcs_vi(j,k,iq_loc(iq))
              ip = ip + 1
           ENDDO
        ENDDO
     ENDDO
     
  ENDDO

! #######################################################################
  DO is = 1,inb_scal
     
! -----------------------------------------------------------------------
! Remove mean field
! -----------------------------------------------------------------------
     ip = 1
     DO k = 1,kmax
        DO j = j1,jmx
           DO i = i1,imx
              wrk3d(ip) = s(i,j,k,is) - bcs_vi_scal(j,k,is)
              ip = ip + 1
           ENDDO
        ENDDO
     ENDDO
     
! -----------------------------------------------------------------------
     CALL OPR_FILTER(ifltmx,jfltmx,kmax, FilterInflow, wrk3d, wrk1d,wrk2d,txc)
     
! -----------------------------------------------------------------------
! Add mean field
! -----------------------------------------------------------------------
     ip = 1
     DO k = 1,kmax
        DO j = j1,jmx
           DO i = i1,imx
              s(i,j,k,is) = wrk3d(ip) + bcs_vi_scal(j,k,is)
              ip = ip + 1
           ENDDO
        ENDDO
     ENDDO
     
  ENDDO

! #######################################################################
! recalculation of diagnostic variables
  IF ( imode_eqns .EQ. DNS_EQNS_INCOMPRESSIBLE .OR. imode_eqns .EQ. DNS_EQNS_ANELASTIC ) THEN
     IF      ( imixture .EQ. MIXT_TYPE_AIRWATER .AND. damkohler(3) .LE. C_0_R ) THEN
        CALL THERMO_AIRWATER_PH(imax,jmax,kmax, s(1,1,1,2), s(1,1,1,1), epbackground,pbackground)
        
     ELSE IF ( imixture .EQ. MIXT_TYPE_AIRWATER_LINEAR                        ) THEN 
        CALL THERMO_AIRWATER_LINEAR(imax,jmax,kmax, s, s(1,1,1,inb_scal_array))
        
     ENDIF

  ELSE
     IF ( imixture .EQ. MIXT_TYPE_AIRWATER ) THEN
        CALL THERMO_AIRWATER_RP(imax,jmax,kmax, s, p, rho, T, wrk3d)
     ELSE
        CALL THERMO_THERMAL_TEMPERATURE(imax,jmax,kmax, s, p, rho, T)
     ENDIF
     CALL THERMO_CALORIC_ENERGY(imax,jmax,kmax, s, T, e)

! This recalculation of T and p is made to make sure that the same numbers are
! obtained in statistics postprocessing as in the simulation; avg* files
! can then be compared with diff command.
     IF ( imixture .EQ. MIXT_TYPE_AIRWATER ) THEN
        CALL THERMO_CALORIC_TEMPERATURE(imax,jmax,kmax, s, e, rho, T, wrk3d)
        CALL THERMO_THERMAL_PRESSURE(imax,jmax,kmax, s, rho, T, p)
     ENDIF
     
     IF ( itransport .EQ. EQNS_TRANS_SUTHERLAND .OR. itransport .EQ. EQNS_TRANS_POWERLAW ) CALL THERMO_VISCOSITY(imax,jmax,kmax, T, vis)

  ENDIF

  RETURN
END SUBROUTINE BOUNDARY_INFLOW_FILTER

END MODULE BOUNDARY_INFLOW
