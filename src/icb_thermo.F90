!==============================================================================
! calculates the empirical melt rates of the iceberg as in 
! Martin: 'Parameterizing the fresh-water flux from land ice to ocean
!          with interactive icebergs in a coupled climate model'(2010)
! and Hellmer et al. (1997).
!
! (notice that the melt rates are in terms of m/s though, not in m/day)
!
!   bottom melt rate	: M_b   [m/s]
!   lateral melt rate	: M_v   [m/s]
!   wave erosion	: M_e   [m/s]
!   lateral (basal) melt rate : M_bv [m/s]
!
!   Thomas Rackow, 29.06.2010
!   - modified 11.06.2014 (	3eq formulation for basal melting;
!				use 3D information for T,S and velocities
!				instead of SSTs; M_v depends on 'thermal driving')
!==============================================================================
subroutine iceberg_meltrates(   M_b, M_v, M_e, M_bv, &
				u_ib,v_ib, uo_ib,vo_ib, ua_ib,va_ib, &
				sst_ib, length_ib, conci_ib, &
				uo_keel_ib, vo_keel_ib, T_keel_ib, S_keel_ib, depth_ib, &
				T_ave_ib, S_ave_ib, ib)
  
  use o_param
  use g_clock
  use g_forcing_arrays
  use g_rotate_grid

  use iceberg_params, only: fwe_flux_ib, fwl_flux_ib, fwb_flux_ib, fwbv_flux_ib, heat_flux_ib
  
  implicit none
  
  real, intent(IN)	:: u_ib,v_ib, uo_ib,vo_ib, ua_ib,va_ib	!iceberg velo, (int.) ocean & atm velo
  real, intent(IN)	:: uo_keel_ib, vo_keel_ib		!ocean velo at iceberg's draft
  real, intent(IN)	:: sst_ib, length_ib, conci_ib 		!SST, length and sea ice conc.
  real, intent(IN)	:: T_keel_ib, S_keel_ib, depth_ib	!T & S at depth 'depth_ib'
  real, intent(IN)	:: T_ave_ib, S_ave_ib			!T & S averaged, i.e. at 'depth_ib/2'
  integer, intent(IN)	:: ib					!iceberg ID
  real, intent(OUT)	:: M_b, M_v, M_e, M_bv			!melt rates [m (ice) per s]	
  	
  
  real			:: absamino, damping, sea_state, v_ibmino
  real			:: tf, T_d 				!freezing temp. and 'thermal driving'

  !3-eq. formulation for bottom melting [m/s]    
  v_ibmino  = sqrt( (u_ib - uo_keel_ib)**2 + (v_ib - vo_keel_ib)**2 )
  call iceberg_heat_water_fluxes_3eq(ib, M_b, T_keel_ib,S_keel_ib,v_ibmino, depth_ib, tf)

  !3-eq. formulation for lateral 'basal' melting [m/s]
  v_ibmino  = sqrt( (u_ib - uo_ib)**2 + (v_ib - vo_ib)**2 ) ! depth-average rel. velocity
  call iceberg_heat_water_fluxes_3eq(ib, M_bv, T_ave_ib,S_ave_ib,v_ibmino, depth_ib/2.0, tf)
  
  !'thermal driving', defined as the elevation of ambient water 
  !temperature above freezing point' (Neshyba and Josberger, 1979).
  T_d = T_ave_ib - tf
  if(T_d < 0.) T_d = 0.
  !write(*,*) 'thermal driving:',T_d,'; Tf:',tf,'T_ave:',T_ave_ib

  !lateral melt (buoyant convection)
  !M_v is a function of the 'thermal driving', NOT just sst! Cf. Neshyba and Josberger (1979)
  M_v = 0.00762 * T_d + 0.00129 * T_d**2
  M_v = M_v/86400.

  !wave erosion
  absamino = sqrt( (ua_ib - uo_ib)**2 + (va_ib - vo_ib)**2 )
  sea_state = 3./2.*sqrt(absamino) + 1./10.*absamino
  damping = 0.5 * (1.0 + cos(conci_ib**3 * Pi))
  M_e = 1./6. * sea_state * (sst_ib + 2.0) * damping
  M_e = M_e/86400.
  !fwe_flux_ib = M_e  
end subroutine iceberg_meltrates


 !***************************************************************************************************************************
 !***************************************************************************************************************************
  
!==============================================================================
! calculates the new iceberg dimensions resulting from melting rates and
! computes the mass (volume) losses
!
!   Thomas Rackow, 29.06.2010
!   - modified 07.06.2014 (changed lateral 'basal' melting, output of averaged volume losses)
!==============================================================================
subroutine iceberg_newdimensions(partit, ib, depth_ib,height_ib,length_ib,width_ib,M_b,M_v,M_e,M_bv, &
				 rho_h2o, rho_icb, file_meltrates)
  
  use o_param !for step_per_day
  use MOD_PARTIT	!for mype
  use g_clock
  use g_forcing_arrays
  use g_rotate_grid
  use iceberg_params, only: l_weeksmellor, ascii_out, icb_outfreq, vl_block, bvl_mean, lvlv_mean, lvle_mean, lvlb_mean, smallestvol_icb, fwb_flux_ib, fwe_flux_ib, fwbv_flux_ib, fwl_flux_ib, scaling, heat_flux_ib, lheat_flux_ib
  use g_config, only: steps_per_ib_step

  implicit none  

  integer, intent(IN)	:: ib
  real, intent(INOUT)	:: depth_ib, height_ib, length_ib, width_ib
  real, intent(IN)	:: M_b, M_v, M_e, M_bv, rho_h2o, rho_icb
  character, intent(IN)	:: file_meltrates*80
  
  real			:: dh_b, dh_v, dh_e, dh_bv, bvl, lvl_b, lvl_v, lvl_e, tvl, volume_before, volume_after
  integer		:: icbID
  logical		:: force_last_output
  real, dimension(4)	:: arr
  integer               :: istep
  ! LA: include latent heat 2023-04-04
  real(kind=8),parameter ::  L                  = 334000.                   ! [J/Kg]

type(t_partit), intent(inout), target :: partit
#include "associate_part_def.h"
#include "associate_part_ass.h"

    !in case the iceberg melts in this step, output has to be written (set to true below)
    force_last_output=.false.

    !changes in this timestep:
    dh_b = M_b*dt*REAL(steps_per_ib_step)   !*scaling(ib)    !change of height..
    dh_v = M_v*dt*REAL(steps_per_ib_step)   !*scaling(ib)    !..and length due to melting..
    dh_e = M_e*dt*REAL(steps_per_ib_step)   !*scaling(ib)    !..and due to wave erosion [m].
    dh_bv = M_bv*dt*REAL(steps_per_ib_step) !*scaling(ib)  !change of length due to 'basal meltrate'
    
    !CALCULATION OF WORKING SURFACES AS IN BIGG (1997) & SILVA (2010)
    !basal volume loss
    bvl = dh_b*length_ib**2
    !lateral volume loss
    !lvl1 = (dh_b+dh_v) *2*length_ib*abs(depth_ib)+ dh_e*length_ib*height_ib
    !lvl2 = (dh_b+dh_v) *2*width_ib*abs(depth_ib) + dh_e*width_ib *height_ib
    lvl_e = dh_e*length_ib*height_ib + dh_e*width_ib*height_ib  ! erosion just at 2 sides
    
    lvl_b = dh_bv*2*length_ib*abs(depth_ib) + dh_bv*2*width_ib*abs(depth_ib)    ! at all 4 sides

    lvl_v = dh_v*2*length_ib*abs(depth_ib) + dh_v*2*width_ib*abs(depth_ib)      ! at all 4 sides
    !total volume loss
    tvl = bvl + lvl_b + lvl_v + lvl_e 	![m^3] per timestep, for freshwater flux convert somehow to [m/s]
    			    		! by distributing over area(iceberg_elem) or over patch
					! surrounding one node
    volume_before=height_ib*length_ib*width_ib

    if((tvl .ge. volume_before) .OR. (volume_before .le. smallestvol_icb)) then
    	volume_after=0.0    	
	depth_ib = 0.0
    	height_ib= 0.0
    	length_ib= 0.0
    	width_ib = 0.0
	tvl	 = volume_before
	! define last tvl to be erosional loss
	bvl = 0.0
	lvl_b = 0.0
	lvl_v = 0.0
	lvl_e = tvl
	force_last_output = .true.
    else
    	volume_after=volume_before-tvl
    
    	!calculating the new iceberg dimensions
	height_ib=  height_ib - dh_b
	depth_ib = -height_ib * rho_icb/rho_h2o
    
    	!calculate length_ib so that new volume is correct
    	length_ib= sqrt(volume_after/height_ib)
    	width_ib = length_ib
    
    	!distribute dh_e equally between length and width
    	!as in code of michael schodlok, but not dh_v? 
    
    	volume_after=height_ib*length_ib*width_ib

        !iceberg smaller than critical value after melting?
        if (volume_after .le. smallestvol_icb) then
            volume_after=0.0    	
	    depth_ib = 0.0
    	    height_ib= 0.0
    	    length_ib= 0.0
    	    width_ib = 0.0
	    tvl	 = volume_before
	    ! define last tvl to be erosional loss
	    bvl = 0.0
	    lvl_b = 0.0
	    lvl_v = 0.0
	    lvl_e = tvl
	    force_last_output = .true.
        end if
    end if
    fwb_flux_ib(ib) = -bvl*rho_icb/rho_h2o/dt/REAL(steps_per_ib_step)*scaling(ib)
    fwe_flux_ib(ib) = -lvl_e*rho_icb/rho_h2o/dt/REAL(steps_per_ib_step)*scaling(ib)
    fwbv_flux_ib(ib) = -lvl_b*rho_icb/rho_h2o/dt/REAL(steps_per_ib_step)*scaling(ib)
    fwl_flux_ib(ib) = -lvl_v*rho_icb/rho_h2o/dt/REAL(steps_per_ib_step)*scaling(ib)

    !stability criterion: icebergs are allowed to roll over
    if(l_weeksmellor) then
      call weeksmellor(	depth_ib, height_ib, length_ib, width_ib, &
      			rho_h2o, rho_icb, volume_after)
    end if   


    !OUTPUT of averaged meltrates in [m^3 (ice) per day]
    bvl_mean(ib)=bvl_mean(ib)+(bvl/real(icb_outfreq)*REAL(steps_per_ib_step)*scaling(ib))
    lvlv_mean(ib)=lvlv_mean(ib)+(lvl_v/real(icb_outfreq)*REAL(steps_per_ib_step)*scaling(ib))
    lvle_mean(ib)=lvle_mean(ib)+(lvl_e/real(icb_outfreq)*REAL(steps_per_ib_step)*scaling(ib))
    lvlb_mean(ib)=lvlb_mean(ib)+(lvl_b/real(icb_outfreq)*REAL(steps_per_ib_step)*scaling(ib))

    !if( (mod(istep,icb_outfreq)==0 .OR. force_last_output) .AND. ascii_out) then
    !  icbID = mype+10
    !  open(unit=icbID,file=file_meltrates,position='append')      
    !  !old: write(icbID,'(6e15.7)') M_b, M_v, M_e, height_ib, length_ib, tvl*step_per_day*steps_per_FESOM_step
    !  tvl=bvl_mean(ib) + lvlv_mean(ib) + lvle_mean(ib) + lvlb_mean(ib)
    !  !new output structure with rev. 20:
    !  write(icbID,'(7e15.7)') 	bvl_mean(ib)*step_per_day, lvlv_mean(ib)*step_per_day, lvle_mean(ib)*step_per_day, &
	!			lvlb_mean(ib)*step_per_day, height_ib, length_ib, tvl*step_per_day
    !  close(icbID)
    !  ! set back to zero for the next round
    !  bvl_mean(ib)=0.0
    !  lvlv_mean(ib)=0.0
    !  lvle_mean(ib)=0.0      
    !  lvlb_mean(ib)=0.0
    !end if

    !values for communication
    arr= [ bvl_mean(ib), lvlv_mean(ib), lvle_mean(ib), lvlb_mean(ib) ] 

    !save in larger array	  
    vl_block((ib-1)*4+1 : ib*4)=arr

    ! -----------------------
    ! LA: set iceberg heatflux at least to latent heat 2023-04-04
    ! Latent heat flux at base and sides also changes lines 475/476
    lheat_flux_ib(ib) = rho_icb*L*tvl*scaling(ib)/dt/REAL(steps_per_ib_step)
    if( (heat_flux_ib(ib).gt.0.0) .and. (heat_flux_ib(ib).lt.lheat_flux_ib(ib))) then
        heat_flux_ib(ib)=lheat_flux_ib(ib)
    end if
    ! -----------------------
end subroutine iceberg_newdimensions


 !***************************************************************************************************************************
 !***************************************************************************************************************************

subroutine weeksmellor(depth_ib, height_ib, length_ib, width_ib, rho_h2o, rho_icb, volume_after)
  implicit none  

  real, intent(INOUT)	:: depth_ib, height_ib, length_ib, width_ib
  real, intent(IN)	:: rho_h2o, rho_icb, volume_after  
  
  logical		:: l_rollover  
    
      !check stability
      l_rollover = (length_ib < sqrt(0.92 * height_ib**2  +  58.32 * height_ib))
    
      if(l_rollover) then
        height_ib= length_ib
        depth_ib = -height_ib * rho_icb/rho_h2o
	
       !calculate length_ib so that 
       !volume is still correct
        length_ib= sqrt(volume_after/height_ib)
        width_ib = length_ib
      end if
  
end subroutine weeksmellor

 !***************************************************************************************************************************
 !***************************************************************************************************************************

subroutine iceberg_heat_water_fluxes_3eq(ib, M_b, T_ib,S_ib,v_rel, depth_ib, t_freeze)
  ! The three-equation model of ice-shelf ocean interaction (Hellmer et al., 1997)
  ! Code derived from BRIOS subroutine iceshelf (which goes back to H.Hellmer's 2D ice shelf model code)
  ! adjusted for use in FESOM by Ralph Timmermann, 16.02.2011
  ! adopted and modified for iceberg basal melting by Thomas Rackow, 11.06.2014
  !----------------------------------------------------------------
  
  use iceberg_params
  use g_config

  implicit none

  integer, INTENT(IN)	  :: ib
  real(kind=8),INTENT(OUT) :: M_b, t_freeze
  real(kind=8),INTENT(IN) :: T_ib, S_ib 	! ocean temperature & salinity (at depth 'depth_ib')
  real(kind=8),INTENT(IN) :: v_rel, depth_ib 	! relative velocity iceberg-ocean (at depth 'depth_ib')

  real (kind=8)  :: temp,sal,tin,zice
  real (kind=8)  :: rhow, rhor, rho
  real (kind=8)  :: gats1, gats2, gas, gat
  real (kind=8)  :: ep1,ep2,ep3,ep4,ep5,ep31
  real (kind=8)  :: ex1,ex2,ex3,ex4,ex5,ex6
  real (kind=8)  :: vt1,sr1,sr2,sf1,sf2,tf1,tf2,tf,sf,seta,re
  integer        :: n, n3, nk

  real(kind=8),parameter ::  rp =   0.                        !reference pressure
  real(kind=8),parameter ::  a   = -0.0575                    !Foldvik&Kvinge (1974)
  real(kind=8),parameter ::  b   =  0.0901
  real(kind=8),parameter ::  c   =  7.61e-4

  real(kind=8),parameter ::  pr  =  13.8                      !Prandtl number      [dimensionless]
  real(kind=8),parameter ::  sc  =  2432.                     !Schmidt number      [dimensionless]
  real(kind=8),parameter ::  ak  =  2.50e-3                   !dimensionless drag coeff.
  real(kind=8),parameter ::  sak1=  sqrt(ak)
  real(kind=8),parameter ::  un  =  1.95e-6                   !kinematic viscosity [m2/s]
  real(kind=8),parameter ::  pr1 =  pr**(2./3.)               !Jenkins (1991)
  real(kind=8),parameter ::  sc1 =  sc**(2./3.)

  real(kind=8),parameter ::  tob=  -20.                       !temperatur at the ice surface
  !real(kind=8),parameter ::  rhoi=  920.                      !mean ice density
  !real(kind=8),parameter ::  rhoh2o=  1027.5		      !water density
  real(kind=8),parameter ::  rhoi=  850.0 		      !mean ice(berg) density (see values in icb_modules.F90)
  real(kind=8),parameter ::  cpw =  4180.0                    !Barnier et al. (1995)
  real(kind=8),parameter ::  lhf =  3.33e+5                   !latent heat of fusion
  real(kind=8),parameter ::  tdif=  1.54e-6                   !thermal conductivity of ice shelf !RG4190 / RG44027
  real(kind=8),parameter ::  atk =  273.15                    !0 deg C in Kelvin
  real(kind=8),parameter ::  cpi =  152.5+7.122*(atk+tob)     !Paterson:"The Physics of Glaciers"

  real(kind=8),parameter ::  L    = 334000.                   ! [J/Kg]

     temp = T_ib
     sal = S_ib
     zice = depth_ib !(<0)

     ! Calculate the in-situ temperature tin
     !call potit(s(i,j,N,lrhs)+35.0,t(i,j,N,lrhs),-zice(i,j),rp,tin)
     call potit_ib(ib, sal,temp,abs(zice),rp,tin)

     ! Calculate or prescribe the turbulent heat and salt transfer coeff. GAT and GAS
     ! velocity-dependent approach of Jenkins (1991)

     vt1  = v_rel ! relative velocity iceberg-ocean (at depth 'depth_ib')
     vt1  = max(vt1,0.005)       ! RG44030

     re   = 10./un                   !vt1*re (=velocity times length scale over kinematic viscosity) is the Reynolds number

     gats1= sak1*vt1
     gats2= 2.12*log(gats1*re)-9.
     gat  = gats1/(gats2+12.5*pr1)
     gas  = gats1/(gats2+12.5*sc1)

     !RG3417 gat  = 1.00e-4   ![m/s]  RT: to be replaced by velocity-dependent equations later
     !RG3417 gas  = 5.05e-7   ![m/s]  RT: to be replaced by velocity-dependent equations later

     ! Calculate
     ! density in the boundary layer: rhow
     ! and interface pressure pg [dbar],
     ! Solve a quadratic equation for the interface salinity sb 
     ! to determine the melting/freezing rate seta.

     call fcn_density(temp,sal,zice,rho)
     rhow = rho !fcn_density returns full in-situ density now!
     ! in previous FESOM version, which has density anomaly from fcn_density, so used density_0+rho  
     ! was rhow= rho0+rho(i,j,N) in BRIOS

     rhor= rhoi/rhow

     ep1 = cpw*gat
     ep2 = cpi*gas
     ep3 = lhf*gas
     ep31 = -rhor*cpi*tdif/zice   !RG4190 / RG44027
     ep4 = b+c*zice
     ep5 = gas/rhor


!rt RG4190     ! negative heat flux term in the ice (due to -kappa/D)
!rt RG4190     ex1 = a*(ep1-ep2)
!rt RG4190     ex2 = ep1*(ep4-tin)+ep2*(tob+a*sal-ep4)-ep3
!rt RG4190     ex3 = sal*(ep2*(ep4-tob)+ep3)


!RT RG4190/RG44027:
!    In case of melting ice account for changing temperature gradient, i.e. switch from heat conduction to heat capacity approach
!TR What to do in iceberg case? LEAVE AS IT IS
     tf = a*sal+ep4
     if(tin.lt.tf) then
       !freezing
       ex1 = a*(ep1+ep31)
       ex2 = ep1*(tin-ep4)+ep3+ep31*(tob-ep4)      ! heat conduction
       ex3 = ep3*sal
       ex6 = 0.5
     else
       !melting
       ex1 = a*(ep1-ep2)
       ex2 = ep1*(ep4-tin)+ep2*(tob+a*sal-ep4)-ep3   ! heat capacity
       ex3 = sal*(ep2*(ep4-tob)+ep3)
       ex6 = -0.5
     endif
!RT RG4190-


     ex4 = ex2/ex1
     ex5 = ex3/ex1

     sr1 = 0.25*ex4*ex4-ex5
     sr2 = ex6*ex4               ! modified for RG4190 / RG44027
     sf1 = sr2+sqrt(sr1)
     tf1 = a*sf1+ep4
     sf2 = sr2-sqrt(sr1)
     tf2 = a*sf2+ep4

     ! Salinities < 0 psu are not defined, therefore pick the positive of the two solutions:
     if(sf1.gt.0.) then
        tf = tf1
        sf = sf1
     else
        tf = tf2
        sf = sf2
     endif

     t_freeze = tf ! output of freezing temperature

     ! Calculate the melting/freezing rate [m/s]
     ! seta = ep5*(1.0-sal/sf)     !rt thinks this is not needed; TR: Why different to M_b? LIQUID vs. ICE

     !rt  t_surf_flux(i,j)=gat*(tf-tin)
     !rt  s_surf_flux(i,j)=gas*(sf-(s(i,j,N,lrhs)+35.0))

     !heat_flux_ib(ib)  = rhow*cpw*gat*(tin-tf)*scaling(ib)      ! [W/m2]  ! positive for upward
     heat_flux_ib(ib)  = rhow*cpw*gat*(tin-tf)*length_ib(ib)*width_ib(ib)*scaling(ib)      ! [W]  ! positive for upward
     !fw_flux_ib(ib) =          gas*(sf-sal)/sf   ! [m/s]   !
      M_b 	    =          gas*(sf-sal)/sf   ! [m/s]   ! m freshwater per second
     !fw_flux_ib(ib) = M_b
     !fw = -M_b
     M_b = - (rhow / rhoi) * M_b 		 ! [m (ice) per second], positive for melting? NOW positive for melting

     !LA avoid basal freezing for grounded icebergs
     if(M_b.lt.0.) then
         M_b = 0.0
     endif

     !      qo=-rhor*seta*oofw
     !      if(seta.le.0.) then
     !         qc=rhor*seta*hemw
     !         qo=rhor*seta*oomw
     !      endif

     ! write(*,'(a10,i10,9f10.3)') 'ice shelf',n,zice,rhow,temp,sal,tin,tf,sf,heat_flux(n),water_flux(n)*86400.*365.

     !for saving to output:
     !net_heat_flux(n)=-heat_flux(n)      ! positive down
     !fresh_wa_flux(n)=-water_flux(n)     ! m freshwater per second

  !enddo

end subroutine iceberg_heat_water_fluxes_3eq

subroutine potit_ib(ib,salz,pt,pres,rfpres,tin)
  ! Berechnet aus dem Salzgehalt[psu] (SALZ), der pot. Temperatur[oC]
  ! (PT) und dem Referenzdruck[dbar] (REFPRES) die in-situ Temperatur
  ! [oC] (TIN) bezogen auf den in-situ Druck[dbar] (PRES) mit Hilfe
  ! eines Iterationsverfahrens aus.

  integer ib
  integer iter
  real salz,pt,pres,rfpres,tin
  real epsi,tpmd,pt1,ptd,pttmpr

  data tpmd / 0.001 /

  epsi = 0.
  do iter=1,100
     tin  = pt+epsi
     pt1  = pttmpr(salz,tin,pres,rfpres)
     ptd  = pt1-pt
     if(abs(ptd).lt.tpmd) return
     epsi = epsi-ptd
  enddo
  write(*,*) ' WARNING FOR ICEBERG #',ib
  write(*,*) ' in-situ temperature calculation has not converged.'
  write(*,*) ' values: salt ', salz,', pot. temp ',pt, ', pressure ', pres, ', refpressure ', rfpres, ', temp ', tin
  stop
  return
end subroutine potit_ib

! if the underlying FESOM is run without cavities, the following routines might be 
! missing, so put them here:
!if (.not. use_cavity) then
!
!-------------------------------------------------------------------------------------
!
!subroutine potit(salz,pt,pres,rfpres,tin)
!  ! Berechnet aus dem Salzgehalt[psu] (SALZ), der pot. Temperatur[oC]
!  ! (PT) und dem Referenzdruck[dbar] (REFPRES) die in-situ Temperatur
!  ! [oC] (TIN) bezogen auf den in-situ Druck[dbar] (PRES) mit Hilfe
!  ! eines Iterationsverfahrens aus.
!
!  integer iter
!  real salz,pt,pres,rfpres,tin
!  real epsi,tpmd,pt1,ptd,pttmpr
!
!  data tpmd / 0.001 /
!
!  epsi = 0.
!  do iter=1,100
!     tin  = pt+epsi
!     pt1  = pttmpr(salz,tin,pres,rfpres)
!     ptd  = pt1-pt
!     if(abs(ptd).lt.tpmd) return
!     epsi = epsi-ptd
!  enddo
!  write(6,*) ' WARNING!'
!  write(6,*) ' in-situ temperature calculation has not converged.'
!  stop
!  return
!end subroutine potit
!
!-------------------------------------------------------------------------------------
!
!real function pttmpr(salz,temp,pres,rfpres)
!  ! Berechnet aus dem Salzgehalt/psu (SALZ), der in-situ Temperatur/degC
!  ! (TEMP) und dem in-situ Druck/dbar (PRES) die potentielle Temperatur/
!  ! degC (PTTMPR) bezogen auf den Referenzdruck/dbar (RFPRES). Es wird
!  ! ein Runge-Kutta Verfahren vierter Ordnung verwendet.
!  ! Checkwert: PTTMPR = 36.89073 DegC
!  !       fuer SALZ   =    40.0 psu
!  !            TEMP   =    40.0 DegC
!  !            PRES   = 10000.000 dbar
!  !            RFPRES =     0.000 dbar
!
!  data ct2 ,ct3  /0.29289322 ,  1.707106781/
!  data cq2a,cq2b /0.58578644 ,  0.121320344/
!  data cq3a,cq3b /3.414213562, -4.121320344/
!
!  real salz,temp,pres,rfpres
!  real p,t,dp,dt,q,ct2,ct3,cq2a,cq2b,cq3a,cq3b
!  real adlprt
!
!  p  = pres
!  t  = temp
!  dp = rfpres-pres
!  dt = dp*adlprt(salz,t,p)
!  t  = t +0.5*dt
!  q = dt
!  p  = p +0.5*dp
!  dt = dp*adlprt(salz,t,p)
!  t  = t + ct2*(dt-q)
!  q  = cq2a*dt + cq2b*q
!  dt = dp*adlprt(salz,t,p)
!  t  = t + ct3*(dt-q)
!  q  = cq3a*dt + cq3b*q
!  p  = rfpres
!  dt = dp*adlprt(salz,t,p)
!
!  pttmpr = t + (dt-q-q)/6.0
!
!end function pttmpr
!
!-------------------------------------------------------------------------------------
!
!real function adlprt(salz,temp,pres)
!  ! Berechnet aus dem Salzgehalt/psu (SALZ), der in-situ Temperatur/degC
!  ! (TEMP) und dem in-situ Druck/dbar (PRES) den adiabatischen Temperatur-
!  ! gradienten/(K Dbar^-1) ADLPRT.
!  ! Checkwert: ADLPRT =     3.255976E-4 K dbar^-1
!  !       fuer SALZ   =    40.0 psu
!  !            TEMP   =    40.0 DegC
!  !            PRES   = 10000.000 dbar
!
!  real salz,temp,pres
!  real s0,a0,a1,a2,a3,b0,b1,c0,c1,c2,c3,d0,d1,e0,e1,e2,ds
!
!  data s0 /35.0/
!  data a0,a1,a2,a3 /3.5803E-5, 8.5258E-6, -6.8360E-8, 6.6228E-10/
!  data b0,b1       /1.8932E-6, -4.2393E-8/
!  data c0,c1,c2,c3 /1.8741E-8, -6.7795E-10, 8.7330E-12, -5.4481E-14/
!  data d0,d1       /-1.1351E-10, 2.7759E-12/
!  data e0,e1,e2    /-4.6206E-13,  1.8676E-14, -2.1687E-16/
!
!  ds = salz-s0
!  adlprt = ( ( (e2*temp + e1)*temp + e0 )*pres                     &
!       + ( (d1*temp + d0)*ds                                  &
!       + ( (c3*temp + c2)*temp + c1 )*temp + c0 ) )*pres   &
!       + (b1*temp + b0)*ds +  ( (a3*temp + a2)*temp + a1 )*temp + a0
!
!END function adlprt
!
!----------------------------------------------------------------------------------------
!
!endif


! LA from oce_dens_press for iceberg coupling
subroutine fcn_density(t,s,z,rho)
  ! The function to calculate insitu density as a function of 
  ! potential temperature (t is relative to the surface)
  ! using the Jackett and McDougall equation of state (1992??)
  !
  ! Should this be updated (1995 or 2003)? The current version is also
  ! different to the international equation of state (Unesco 1983). 
  ! What is the exact reference for this version then? 
  ! A question mark from Qiang 02,07,2010.  
  !
  ! Coded by ??
  ! Reviewed by ??
  !-------------------------------------------------------------------


  use o_PARAM
  implicit none

  real(kind=8), intent(IN)       :: t, s, z
  real(kind=8), intent(OUT)      :: rho                 
  real(kind=8)                   :: rhopot, bulk

 bulk = 19092.56 + t*(209.8925 				&
      - t*(3.041638 - t*(-1.852732e-3			&
      - t*(1.361629e-5))))				&
      + s*(104.4077 - t*(6.500517			&
      -  t*(.1553190 - t*(-2.326469e-4))))		&
      + sqrt(s**3)*(-5.587545				&
      + t*(0.7390729 - t*(1.909078e-2)))		&
      - z *(4.721788e-1 + t*(1.028859e-2		&
      + t*(-2.512549e-4 - t*(5.939910e-7))))		&
      - z*s*(-1.571896e-2				&
      - t*(2.598241e-4 + t*(-7.267926e-6)))		&
      - z*sqrt(s**3)					&
      *2.042967e-3 + z*z*(1.045941e-5			&
      - t*(5.782165e-10 - t*(1.296821e-7)))		&
      + z*z*s						&
      *(-2.595994e-7					&
      + t*(-1.248266e-9 + t*(-3.508914e-9)))

 rhopot = ( 999.842594					&
      + t*( 6.793952e-2			&
      + t*(-9.095290e-3			&
      + t*( 1.001685e-4			&
      + t*(-1.120083e-6			&
      + t*( 6.536332e-9)))))			&
      + s*( 0.824493				&
      + t *(-4.08990e-3			&
      + t *( 7.64380e-5			&
      + t *(-8.24670e-7			&
      + t *( 5.38750e-9)))))			&
      + sqrt(s**3)*(-5.72466e-3		&
      + t*( 1.02270e-4			&
      + t*(-1.65460e-6)))			&
      + 4.8314e-4*s**2)
 rho = rhopot / (1.0 + 0.1*z/bulk)
end subroutine fcn_density
