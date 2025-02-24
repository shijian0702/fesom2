module oce_adv_tra_driver_interfaces
  interface
   subroutine do_oce_adv_tra(dt, vel, w, wi, we, tr_num, tracers, partit, mesh)
      use MOD_MESH
      use MOD_TRACER
      use MOD_PARTIT
      real(kind=WP),  intent(in),    target :: dt
      integer,        intent(in)            :: tr_num
      type(t_partit), intent(inout), target :: partit
      type(t_mesh),   intent(in),    target :: mesh
      type(t_tracer), intent(inout), target :: tracers
      real(kind=WP),  intent(in)            :: vel(2, mesh%nl-1, partit%myDim_elem2D+partit%eDim_elem2D)
      real(kind=WP),  intent(in), target    :: W(mesh%nl,    partit%myDim_nod2D+partit%eDim_nod2D)
      real(kind=WP),  intent(in), target    :: WI(mesh%nl,   partit%myDim_nod2D+partit%eDim_nod2D)
      real(kind=WP),  intent(in), target    :: WE(mesh%nl,   partit%myDim_nod2D+partit%eDim_nod2D)
    end subroutine
  end interface
end module

module oce_tra_adv_flux2dtracer_interface
  interface
    subroutine oce_tra_adv_flux2dtracer(dt, dttf_h, dttf_v, flux_h, flux_v, partit, mesh, use_lo, ttf, lo)
      !update the solution for vertical and horizontal flux contributions
      use MOD_MESH
      use MOD_PARTIT
      real(kind=WP), intent(in),    target :: dt
      type(t_partit),intent(inout), target :: partit
      type(t_mesh),  intent(in),    target :: mesh
      real(kind=WP), intent(inout)      :: dttf_h(mesh%nl-1, partit%myDim_nod2D+partit%eDim_nod2D)
      real(kind=WP), intent(inout)      :: dttf_v(mesh%nl-1, partit%myDim_nod2D+partit%eDim_nod2D)
      real(kind=WP), intent(inout)      :: flux_h(mesh%nl-1, partit%myDim_edge2D)
      real(kind=WP), intent(inout)      :: flux_v(mesh%nl,   partit%myDim_nod2D)
      logical,       optional           :: use_lo
      real(kind=WP), optional           :: ttf(mesh%nl-1, partit%myDim_nod2D+partit%eDim_nod2D)
      real(kind=WP), optional           :: lo (mesh%nl-1, partit%myDim_nod2D+partit%eDim_nod2D)
    end subroutine
  end interface
end module
!
!
!===============================================================================
subroutine do_oce_adv_tra(dt, vel, w, wi, we, tr_num, tracers, partit, mesh)
    use MOD_MESH
    use MOD_TRACER
    use MOD_PARTIT
    use g_comm_auto
    use oce_adv_tra_hor_interfaces
    use oce_adv_tra_ver_interfaces
    use oce_adv_tra_fct_interfaces
    use oce_tra_adv_flux2dtracer_interface
    implicit none
    real(kind=WP),  intent(in),    target :: dt
    integer,        intent(in)            :: tr_num
    type(t_partit), intent(inout), target :: partit
    type(t_mesh),   intent(in),    target :: mesh
    type(t_tracer), intent(inout), target :: tracers
    real(kind=WP),  intent(in)            :: vel(2, mesh%nl-1, partit%myDim_elem2D+partit%eDim_elem2D)
    real(kind=WP),  intent(in), target    :: W(mesh%nl,    partit%myDim_nod2D+partit%eDim_nod2D)
    real(kind=WP),  intent(in), target    :: WI(mesh%nl,   partit%myDim_nod2D+partit%eDim_nod2D)
    real(kind=WP),  intent(in), target    :: WE(mesh%nl,   partit%myDim_nod2D+partit%eDim_nod2D)

    real(kind=WP),  pointer, dimension (:,:)   :: pwvel
    real(kind=WP),  pointer, dimension (:,:)   :: ttf, ttfAB, fct_LO
    real(kind=WP),  pointer, dimension (:,:)   :: adv_flux_hor, adv_flux_ver, dttf_h, dttf_v
    real(kind=WP),  pointer, dimension (:,:)   :: fct_ttf_min, fct_ttf_max
    real(kind=WP),  pointer, dimension (:,:)   :: fct_plus, fct_minus

    integer,        pointer, dimension (:)     :: nboundary_lay
    real(kind=WP),  pointer, dimension (:,:,:) :: edge_up_dn_grad

    integer       :: el(2), enodes(2), nz, n, e
    integer       :: nl12, nu12, nl1, nl2, nu1, nu2
    real(kind=WP) :: cLO, cHO, deltaX1, deltaY1, deltaX2, deltaY2
    real(kind=WP) :: qc, qu, qd
    real(kind=WP) :: tvert(mesh%nl), tvert_e(mesh%nl), a, b, c, d, da, db, dg, vflux, Tupw1
    real(kind=WP) :: Tmean, Tmean1, Tmean2, num_ord
    real(kind=WP) :: opth, optv
    logical       :: do_zero_flux

#include "associate_part_def.h"
#include "associate_mesh_def.h"
#include "associate_part_ass.h"
#include "associate_mesh_ass.h"
    ttf             => tracers%data(tr_num)%values
    ttfAB           => tracers%data(tr_num)%valuesAB
    opth            =  tracers%data(tr_num)%tra_adv_ph
    optv            =  tracers%data(tr_num)%tra_adv_pv
    fct_LO          => tracers%work%fct_LO
    adv_flux_ver    => tracers%work%adv_flux_ver
    adv_flux_hor    => tracers%work%adv_flux_hor
    edge_up_dn_grad => tracers%work%edge_up_dn_grad
    nboundary_lay   => tracers%work%nboundary_lay
    fct_ttf_min     => tracers%work%fct_ttf_min
    fct_ttf_max     => tracers%work%fct_ttf_max
    fct_plus        => tracers%work%fct_plus
    fct_minus       => tracers%work%fct_minus
    dttf_h          => tracers%work%del_ttf_advhoriz
    dttf_v          => tracers%work%del_ttf_advvert
    !___________________________________________________________________________
    ! compute FCT horzontal and vertical low order solution as well as lw order 
    ! part of antidiffusive flux
    if (trim(tracers%data(tr_num)%tra_adv_lim)=='FCT') then 
        ! compute the low order upwind horizontal flux
        ! init_zero=.true.  : zero the horizontal flux before computation
        ! init_zero=.false. : input flux will be substracted
        call adv_tra_hor_upw1(vel, ttf, partit, mesh, adv_flux_hor, init_zero=.true.)
        ! update the LO solution for horizontal contribution
        fct_LO=0.0_WP
        do e=1, myDim_edge2D
            enodes=edges(:,e)
            el=edge_tri(:,e)        
            nl1=nlevels(el(1))-1
            nu1=ulevels(el(1))
            nl2=0
            nu2=0
            if(el(2)>0) then
                nl2=nlevels(el(2))-1
                nu2=ulevels(el(2))
            end if     
            
            nl12 = max(nl1,nl2)
            nu12 = nu1
            if (nu2>0) nu12 = min(nu1,nu2)
            
            !!PS do  nz=1, max(nl1, nl2)
            do nz=nu12, nl12
                fct_LO(nz, enodes(1))=fct_LO(nz, enodes(1))+adv_flux_hor(nz, e)
                fct_LO(nz, enodes(2))=fct_LO(nz, enodes(2))-adv_flux_hor(nz, e)
            end do
        end do 
        ! compute the low order upwind vertical flux (explicit part only)
        ! zero the input/output flux before computation
        call adv_tra_ver_upw1(we, ttf, partit, mesh, adv_flux_ver, init_zero=.true.)        
        ! update the LO solution for vertical contribution
        do n=1, myDim_nod2D
            nu1 = ulevels_nod2D(n)
            nl1 = nlevels_nod2D(n)
            !!PS do  nz=1, nlevels_nod2D(n)-1
            do  nz= nu1, nl1-1
                fct_LO(nz,n)=(ttf(nz,n)*hnode(nz,n)+(fct_LO(nz,n)+(adv_flux_ver(nz, n)-adv_flux_ver(nz+1, n)))*dt/areasvol(nz,n))/hnode_new(nz,n)
            end do
        end do
        if (w_split) then !wvel/=wvel_e
            ! update for implicit contribution (w_split option)
            call adv_tra_vert_impl(dt, wi, fct_LO, partit, mesh)
            ! compute the low order upwind vertical flux (full vertical velocity)
            ! zero the input/output flux before computation
            ! --> compute here low order part of vertical anti diffusive fluxes, 
            !     has to be done on the full vertical velocity w
            call adv_tra_ver_upw1(w, ttf, partit, mesh, adv_flux_ver, init_zero=.true.)
        end if    
        call exchange_nod(fct_LO, partit)
    end if

    do_zero_flux=.true.
    if (trim(tracers%data(tr_num)%tra_adv_lim)=='FCT') do_zero_flux=.false.
    !___________________________________________________________________________
    ! do horizontal tracer advection, in case of FCT high order solution 
    SELECT CASE(trim(tracers%data(tr_num)%tra_adv_hor))
        CASE('MUSCL')
            ! compute the untidiffusive horizontal flux (init_zero=.false.: input is the LO horizontal flux computed above)
            call adv_tra_hor_muscl(vel, ttfAB, partit, mesh, opth,  adv_flux_hor, edge_up_dn_grad, nboundary_lay, init_zero=do_zero_flux)
        CASE('MFCT')
             call adv_tra_hor_mfct(vel, ttfAB, partit, mesh, opth,  adv_flux_hor, edge_up_dn_grad,                init_zero=do_zero_flux)
        CASE('UPW1')
             call adv_tra_hor_upw1(vel, ttfAB, partit, mesh,        adv_flux_hor,                                 init_zero=do_zero_flux)
        CASE DEFAULT !unknown
            if (mype==0) write(*,*) 'Unknown horizontal advection type ',  trim(tracers%data(tr_num)%tra_adv_hor), '! Check your namelists!'
            call par_ex(partit, 1)
    END SELECT
    if (trim(tracers%data(tr_num)%tra_adv_lim)=='FCT') then
       pwvel=>w
    else
       pwvel=>we
    end if
    !___________________________________________________________________________
    ! do vertical tracer advection, in case of FCT high order solution 
    SELECT CASE(trim(tracers%data(tr_num)%tra_adv_ver))
        CASE('QR4C')
            ! compute the untidiffusive vertical flux   (init_zero=.false.:input is the LO vertical flux computed above)
            call adv_tra_ver_qr4c (   pwvel, ttfAB, partit, mesh, optv, adv_flux_ver, init_zero=do_zero_flux)
        CASE('CDIFF')
            call adv_tra_ver_cdiff(   pwvel, ttfAB, partit, mesh,       adv_flux_ver, init_zero=do_zero_flux)
        CASE('PPM')
            call adv_tra_vert_ppm(dt, pwvel, ttfAB, partit, mesh,       adv_flux_ver, init_zero=do_zero_flux)
        CASE('UPW1')
            call adv_tra_ver_upw1 (   pwvel, ttfAB, partit, mesh,       adv_flux_ver, init_zero=do_zero_flux)
        CASE DEFAULT !unknown
            if (mype==0) write(*,*) 'Unknown vertical advection type ',  trim(tracers%data(tr_num)%tra_adv_ver), '! Check your namelists!'
            call par_ex(1)
        ! --> be aware the vertical implicite part in case without FCT is done in 
        !     oce_ale_tracer.F90 --> subroutine diff_ver_part_impl_ale(tr_num, partit, mesh)
        !     for do_wimpl=.true.
    END SELECT
    !___________________________________________________________________________
    !
    if (trim(tracers%data(tr_num)%tra_adv_lim)=='FCT') then
       !edge_up_dn_grad will be used as an auxuary array here
       call oce_tra_adv_fct(dt, ttf, fct_LO, adv_flux_hor, adv_flux_ver, fct_ttf_min, fct_ttf_max, fct_plus, fct_minus, edge_up_dn_grad, partit, mesh)
       call oce_tra_adv_flux2dtracer(dt, dttf_h, dttf_v, adv_flux_hor, adv_flux_ver, partit, mesh, use_lo=.TRUE., ttf=ttf, lo=fct_LO)
    else
       call oce_tra_adv_flux2dtracer(dt, dttf_h, dttf_v, adv_flux_hor, adv_flux_ver, partit, mesh)
    end if
end subroutine do_oce_adv_tra
!
!
!===============================================================================
subroutine oce_tra_adv_flux2dtracer(dt, dttf_h, dttf_v, flux_h, flux_v, partit, mesh, use_lo, ttf, lo)
    use MOD_MESH
    use o_ARRAYS
    use MOD_PARTIT
    use g_comm_auto
    implicit none
    real(kind=WP), intent(in),    target :: dt
    type(t_partit),intent(inout), target :: partit
    type(t_mesh),  intent(in),    target :: mesh
    real(kind=WP), intent(inout)      :: dttf_h(mesh%nl-1, partit%myDim_nod2D+partit%eDim_nod2D)
    real(kind=WP), intent(inout)      :: dttf_v(mesh%nl-1, partit%myDim_nod2D+partit%eDim_nod2D)
    real(kind=WP), intent(inout)      :: flux_h(mesh%nl-1, partit%myDim_edge2D)
    real(kind=WP), intent(inout)      :: flux_v(mesh%nl,   partit%myDim_nod2D)
    logical,       optional           :: use_lo
    real(kind=WP), optional           :: lo (mesh%nl-1, partit%myDim_nod2D+partit%eDim_nod2D)
    real(kind=WP), optional           :: ttf(mesh%nl-1, partit%myDim_nod2D+partit%eDim_nod2D)
    integer                           :: n, nz, k, elem, enodes(3), num, el(2), nu12, nl12, nu1, nu2, nl1, nl2, edge
#include "associate_part_def.h"
#include "associate_mesh_def.h"
#include "associate_part_ass.h"
#include "associate_mesh_ass.h"
    !___________________________________________________________________________
    ! c. Update the solution
    ! Vertical
    if (present(use_lo)) then
       if (use_lo) then
          do n=1, myDim_nod2d
             nu1 = ulevels_nod2D(n)
             nl1 = nlevels_nod2D(n)
             !!PS do nz=1,nlevels_nod2D(n)-1
             do nz=nu1, nl1-1  
                dttf_v(nz,n)=dttf_v(nz,n)-ttf(nz,n)*hnode(nz,n)+LO(nz,n)*hnode_new(nz,n)
             end do
           end do
       end if
    end if

    do n=1, myDim_nod2d
        nu1 = ulevels_nod2D(n)
        nl1 = nlevels_nod2D(n)
        do nz=nu1,nl1-1  
            dttf_v(nz,n)=dttf_v(nz,n) + (flux_v(nz,n)-flux_v(nz+1,n))*dt/areasvol(nz,n)
        end do
    end do

    
    ! Horizontal
    do edge=1, myDim_edge2D
        enodes(1:2)=edges(:,edge)
        el=edge_tri(:,edge)
        nl1=nlevels(el(1))-1
        nu1=ulevels(el(1))
        
        nl2=0
        nu2=0
        if(el(2)>0) then
            nl2=nlevels(el(2))-1
            nu2=ulevels(el(2))
        end if 
        
        nl12 = max(nl1,nl2)
        nu12 = nu1
        if (nu2>0) nu12 = min(nu1,nu2)
            
        !!PS do  nz=1, max(nl1, nl2)
        do nz=nu12, nl12
            dttf_h(nz,enodes(1))=dttf_h(nz,enodes(1))+flux_h(nz,edge)*dt/areasvol(nz,enodes(1))
            dttf_h(nz,enodes(2))=dttf_h(nz,enodes(2))-flux_h(nz,edge)*dt/areasvol(nz,enodes(2))
        end do
    end do
end subroutine oce_tra_adv_flux2dtracer
