#include "types.h"
#include "dns_error.h"
#include "dns_const.h"

!########################################################################
!# HISTORY
!#
!# 2014/03 - L. Muessle
!#           Created
!# 2017/12 - J.P. Mellado
!#           Cleaned
!#
!########################################################################

SUBROUTINE PARTICLE_READ_GLOBAL(inifile)
    
  USE DNS_CONSTANTS, ONLY : efile, lfile
  USE DNS_GLOBAL,    ONLY : inb_flow_array, inb_scal_array
  USE DNS_GLOBAL,    ONLY : imax,jmax,kmax, isize_wrk2d
  USE DNS_GLOBAL,    ONLY : g
  USE DNS_GLOBAL,    ONLY : icalc_part, isize_particle, inb_part_array, inb_part_txc, inb_part 
  USE LAGRANGE_GLOBAL
#ifdef USE_MPI
  USE DNS_MPI, ONLY : ims_npro
#endif

  IMPLICIT NONE

  CHARACTER*(*) inifile

! -------------------------------------------------------------------
  CHARACTER*512 sRes
  CHARACTER*32 bakfile
  TINTEGER idummy
  TREAL memory_factor
  
! ###################################################################
  bakfile = TRIM(ADJUSTL(inifile))//'.bak'

  CALL IO_WRITE_ASCII(lfile, 'Reading particle input data.')

! -------------------------------------------------------------------
  CALL IO_WRITE_ASCII(bakfile,  '#')
  CALL IO_WRITE_ASCII(bakfile,  '#[Lagrange]')
  CALL IO_WRITE_ASCII(bakfile,  '#Type=<value>')
  CALL IO_WRITE_ASCII(bakfile,  '#Particle_number=<value>')
  CALL IO_WRITE_ASCII(bakfile,  '#Particle_rnd_mode=<value>')
  CALL IO_WRITE_ASCII(bakfile,  '#Y_Particle_Pos=<value>')
  CALL IO_WRITE_ASCII(bakfile,  '#Y_Particle_Width=<value>')
  CALL IO_WRITE_ASCII(bakfile,  '#Particle_bumper=<value>')

! -------------------------------------------------------------------
  CALL SCANINICHAR(bakfile, inifile, 'Lagrange', 'Type', 'None', sRes)
  IF      ( TRIM(ADJUSTL(sRes)) .EQ. 'none'              ) THEN; ilagrange = LAG_TYPE_NONE
  ELSE IF ( TRIM(ADJUSTL(sRes)) .EQ. 'tracer'            ) THEN; ilagrange = LAG_TYPE_TRACER
  ELSE IF ( TRIM(ADJUSTL(sRes)) .EQ. 'simplesettling'    ) THEN; ilagrange = LAG_TYPE_SIMPLE_SETT
  ELSE IF ( TRIM(ADJUSTL(sRes)) .EQ. 'bilinearcloudthree') THEN; ilagrange = LAG_TYPE_BIL_CLOUD_3
  ELSE IF ( TRIM(ADJUSTL(sRes)) .EQ. 'bilinearcloudfour' ) THEN; ilagrange = LAG_TYPE_BIL_CLOUD_4
  ELSE 
     CALL IO_WRITE_ASCII(efile, 'PARTICLE_READ_GLOBAL. Wrong lagrangian model.')
     CALL DNS_STOP(DNS_ERROR_OPTION)
  ENDIF

  CALL SCANINILONGINT(bakfile, inifile, 'Lagrange', 'Particle_number', '0', particle_number_total  )
  CALL SCANINIREAL(bakfile, inifile, 'Lagrange', 'Particle_bumper', '2.0', memory_factor  )

! -------------------------------------------------------------------
  CALL SCANINIINT(bakfile, inifile, 'Lagrange', 'Particle_rnd_mode', '1', particle_rnd_mode  )
  CALL SCANINIREAL(bakfile, inifile, 'Lagrange', 'Y_Particle_Pos', '0.5', y_particle_pos  )
  CALL SCANINIREAL(bakfile, inifile, 'Lagrange', 'Y_Particle_Width', '1.0', y_particle_width  )

! -------------------------------------------------------------------
  CALL SCANINICHAR(bakfile, inifile, 'Lagrange', 'CalculateParticlePDF', 'no', sRes)
  IF     ( TRIM(ADJUSTL(sRes)) .eq. 'yes' ) THEN; icalc_part_pdf = 1
  ELSEIF ( TRIM(ADJUSTL(sRes)) .eq. 'no'  ) THEN; icalc_part_pdf = 0
  ENDIF
  CALL SCANINICHAR(bakfile, inifile, 'Lagrange', 'ParticlePdfSubdomain', '-1', sRes)
  particle_pdf_subdomain = C_0_R; idummy = 6
  CALL LIST_REAL(sRes, idummy, particle_pdf_subdomain)
  CALL SCANINIREAL(bakfile, inifile, 'Lagrange', 'ParticlePdfMax', '10', particle_pdf_max  )
  CALL SCANINIREAL(bakfile, inifile, 'Lagrange', 'ParticlePdfInterval', '0.5', particle_pdf_interval  )

  CALL SCANINICHAR(bakfile, inifile, 'Lagrange', 'ResidenceReset', 'yes', sRes)
  IF     ( TRIM(ADJUSTL(sRes)) .eq. 'yes' ) THEN; residence_reset = 1
  ELSEIF ( TRIM(ADJUSTL(sRes)) .eq. 'no'  ) THEN; residence_reset = 0
  ELSE
     CALL IO_WRITE_ASCII(efile,'PARTICLE_READ_GLOBAL. ResidenceReset must be yes or no')
     CALL DNS_STOP(DNS_ERROR_RESIDENCERESET)
  ENDIF

  CALL SCANINICHAR(bakfile, inifile, 'Lagrange', 'Parameters', '0.0', sRes)
  idummy = MAX_LAGPARAM
  CALL LIST_REAL(sRes, idummy, lagrange_param)
  
! -------------------------------------------------------------------
  inb_trajectory = inb_flow_array + inb_scal_array
  CALL SCANINICHAR(bakfile, inifile, 'Lagrange', 'TrajectoryType', 'first', sRes)
  IF     ( TRIM(ADJUSTL(sRes)) .eq. 'first'     ) THEN; itrajectory = LAG_TRAJECTORY_FIRST
  ELSEIF ( TRIM(ADJUSTL(sRes)) .eq. 'vorticity' ) THEN; itrajectory = LAG_TRAJECTORY_VORTICITY
     inb_trajectory = inb_trajectory + 3 ! + vorticity
  ELSEIF ( TRIM(ADJUSTL(sRes)) .eq. 'largest'   ) THEN; itrajectory = LAG_TRAJECTORY_LARGEST
  ELSEIF ( TRIM(ADJUSTL(sRes)) .eq. 'none'      ) THEN; itrajectory = LAG_TRAJECTORY_NONE
  ELSE
     CALL IO_WRITE_ASCII(efile,'PARTICLE_READ_GLOBAL. Invalid option in TrajectoryType')
     CALL DNS_STOP(DNS_ERROR_CALCTRAJECTORIES)
  ENDIF

  CALL SCANINIINT(bakfile, inifile, 'Lagrange', 'TrajectoryNumber', '0', isize_trajectory)
  IF ( isize_trajectory .GT. particle_number_total ) THEN
     CALL IO_WRITE_ASCII(efile,'PARTICLE_READ_GLOBAL. Number of trajectories must be less or equal than number of particles.')
     CALL DNS_STOP(DNS_ERROR_CALCTRAJECTORIES)
  ENDIF
  IF ( isize_trajectory .LE. 0 ) itrajectory = LAG_TRAJECTORY_NONE
  IF ( icalc_part .EQ. 0 )       itrajectory = LAG_TRAJECTORY_NONE
     
! ###################################################################
! Initializing size of Lagrangian arrays
! ###################################################################
! -------------------------------------------------------------------
! default
  inb_part_array      = 3 ! # of particle properties in array
  inb_part            = 3 ! # of particle properties in Runge-Kutta
  inb_part_txc        = 1
  inb_particle_interp = 3
  
  IF (ilagrange .EQ. LAG_TYPE_BIL_CLOUD_3) THEN
     inb_part_array       = 5
     inb_part             = 5
     inb_part_txc         = 4          
     inb_particle_interp  = inb_particle_interp +4
     LAGRANGE_SPNAME(1)   = 'droplet_diff_3'
     LAGRANGE_SPNAME(2)   = 'droplet_nodiff_3'
     
  ELSEIF (ilagrange .EQ. LAG_TYPE_BIL_CLOUD_4) THEN
     inb_part_array       = 5 +2 ! Space for residence time pdf
     inb_part             = 5
     inb_part_txc         = 4
     inb_particle_interp  = inb_particle_interp +4
     LAGRANGE_SPNAME(1)   = 'droplet_diff_3'
     LAGRANGE_SPNAME(2)   = 'droplet_nodiff_3'
     LAGRANGE_SPNAME(3)   = 'residence_part'
     
  END IF

#ifdef USE_MPI
  isize_particle = INT( particle_number_total /INT(ims_npro, KIND=8) )
  IF ( MOD(particle_number_total, INT(ims_npro, KIND=8)) .NE. 0 ) THEN ! All PEs with equal memory
     isize_particle = isize_particle +1
  ENDIF
  isize_particle = isize_particle *INT( memory_factor *100 ) /100
#else
  isize_particle = INT(particle_number_total)
#endif

  IF ( itrajectory .NE. LAG_TRAJECTORY_NONE ) THEN
     inb_part_txc        = MAX(inb_part_txc,inb_flow_array+inb_scal_array-3)
     inb_particle_interp = MAX(inb_particle_interp,inb_trajectory)
  ENDIF
  
  isize_pbuffer = int(isize_particle/4*(inb_part_array*2+1) ) !same size for both buffers
  isize_l_comm  = 2     *jmax*kmax   *inb_particle_interp &
                +   imax*jmax     *2 *inb_particle_interp &
                + 2     *jmax     *2 *inb_particle_interp 
  isize_l_comm  = MAX(isize_l_comm,2*isize_pbuffer)

  idummy = MAX((imax+1)*jmax, MAX((imax+1)*kmax,jmax*(kmax+1)))
  isize_wrk2d = MAX(isize_wrk2d,idummy)

  RETURN  
END SUBROUTINE PARTICLE_READ_GLOBAL
