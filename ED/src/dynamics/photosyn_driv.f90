!==========================================================================================!
!==========================================================================================!
!     This subroutine will control the photosynthesis scheme (Farquar and Leuning).  This  !
! is called every step, but not every sub-step.                                            !
!------------------------------------------------------------------------------------------!
subroutine canopy_photosynthesis(csite,cmet,mzg,ipa,ed_ktrans,lsl,sum_lai_rbi              &
                                ,leaf_aging_factor,green_leaf_factor)
   use ed_state_vars  , only : sitetype          & ! structure
                             , patchtype         ! ! structure
   use ed_max_dims    , only : n_pft             ! ! intent(in)
   use pft_coms       , only : leaf_width        & ! intent(in)
                             , water_conductance & ! intent(in)
                             , q                 & ! intent(in)
                             , qsw               & ! intent(in)
                             , include_pft       ! ! intent(in)
   use soil_coms      , only : soil              & ! intent(in)
                             , dslz              ! ! intent(in)
   use consts_coms    , only : t00               & ! intent(in)
                             , epi               & ! intent(in)
                             , wdnsi             & ! intent(in)
                             , wdns              & ! intent(in)
                             , kgCday_2_umols    ! ! intent(in)
   use met_driver_coms, only : met_driv_state    ! ! structure
   use physiology_coms, only : print_photo_debug ! ! intent(in)
   implicit none
   !----- Arguments -----------------------------------------------------------------------!
   type(sitetype)            , target      :: csite             ! Current site
   type(met_driv_state)      , target      :: cmet              ! Current met. conditions.
   integer                   , intent(in)  :: ipa               ! Current patch #
   integer                   , intent(in)  :: lsl               ! Lowest soil level
   integer                   , intent(in)  :: mzg               ! Number of soil layers
   real   , dimension(n_pft) , intent(in)  :: leaf_aging_factor ! 
   real   , dimension(n_pft) , intent(in)  :: green_leaf_factor ! 
   integer, dimension(mzg)   , intent(out) :: ed_ktrans         ! 
   real                      , intent(out) :: sum_lai_rbi       ! 
   !----- Local variables -----------------------------------------------------------------!
   type(patchtype)           , pointer     :: cpatch             ! Current site
   integer                                 :: ico                ! Current cohort #
   integer                                 :: tuco               ! Tallest used cohort
   integer                                 :: ipft
   integer                                 :: k1
   integer                                 :: k2
   integer                                 :: nsoil
   integer                                 :: limit_flag
   logical, dimension(mzg)                 :: root_depth_indices ! 
   logical                                 :: las
   real   , dimension(mzg)                 :: available_liquid_water
   real                                    :: leaf_resp
   real                                    :: mixrat
   real                                    :: parv_o_lai
   real                                    :: P_op
   real                                    :: P_cl
   real                                    :: ci_op
   real                                    :: ci_cl
   real                                    :: slpotv
   real                                    :: swp
   real                                    :: water_demand
   real                                    :: water_supply
   real                                    :: broot_tot
   real                                    :: broot_loc
   real                                    :: pss_available_water
   !---------------------------------------------------------------------------------------!


   !----- Pointing to the cohort structures -----------------------------------------------!
   cpatch => csite%patch(ipa)

   !----- Finding the patch-level Total Leaf and Wood Area Index. -------------------------!
   csite%lai(ipa) = 0.0
   csite%wpa(ipa) = 0.0
   csite%wai(ipa) = 0.0
   do ico=1,cpatch%ncohorts
      csite%lai(ipa)  = csite%lai(ipa)  + cpatch%lai(ico)
      csite%wpa(ipa)  = csite%wpa(ipa)  + cpatch%wpa(ico)
      csite%wai(ipa)  = csite%wai(ipa)  + cpatch%wai(ico)
   end do


   !----- Calculate liquid water available for transpiration. -----------------------------!
   nsoil = csite%ntext_soil(mzg,ipa)
   available_liquid_water(mzg) = wdns * dslz(mzg) * csite%soil_fracliq(mzg,ipa)            &
                               * max(0.0, csite%soil_water(mzg,ipa) - soil(nsoil)%soilwp )
   do k1 = mzg-1, lsl, -1
      nsoil = csite%ntext_soil(k1,ipa)
      available_liquid_water(k1) = available_liquid_water(k1+1)                            &
                                 + wdns * dslz(k1) * csite%soil_fracliq(k1,ipa)            &
                                 * max(0.0, csite%soil_water(k1,ipa) - soil(nsoil)%soilwp )
   end do
   !---------------------------------------------------------------------------------------!

   !---------------------------------------------------------------------------------------!
   !     Initialize the array of maximum photosynthesis rates used in the mortality        !
   ! function.                                                                             !
   !---------------------------------------------------------------------------------------!
   csite%A_o_max(1:n_pft,ipa) = 0.0
   csite%A_c_max(1:n_pft,ipa) = 0.0

   !---------------------------------------------------------------------------------------!
   !     Find the tallest cohort with TAI above minimum, sufficient heat capacity, and not !
   ! buried in snow.  The first two conditions are redundant, but we will keep them for    !
   ! the time being, so it is going to be safer.                                           !
   !---------------------------------------------------------------------------------------!
   las = .false.
   do ico = 1,cpatch%ncohorts
      !----- If this is the tallest cohort to be used, we save its index. -----------------!
      if (.not. las .and. cpatch%solvable(ico)) then
         las  = .true.
         tuco = ico
      end if
   end do

   !---------------------------------------------------------------------------------------!
   !---------------------------------------------------------------------------------------!
   !    There is at least one cohort that meet requirements.  And this is tallest one, so  !
   ! we can use it to compute the maximum photosynthetic rates, i.e., the rate the cohort  !
   ! would have if it were at the top of the canopy.  This is used for the mortality       !
   ! function.                                                                             !
   !---------------------------------------------------------------------------------------!
   if (las) then
      !----- We now loop over PFTs, not cohorts, skipping those we are not using. ---------!
      do ipft = 1, n_pft
         if (include_pft(ipft) == 1)then

            !------------------------------------------------------------------------------!
            !    Convert specific humidity to mixing ratio.  I am not sure about this one, !
            ! if we should convert here to mixing ratio, or convert everything inside to   !
            ! specific humidity.  Also, scale photosynthetically active radiation per unit !
            ! of leaf.                                                                     !
            !------------------------------------------------------------------------------!
            mixrat     = csite%can_shv(ipa) / (1. - csite%can_shv(ipa))
            parv_o_lai = cpatch%par_v(tuco) / cpatch%lai(tuco)

            !----- Calling the photosynthesis for maximum photosynthetic rates. -----------!
            call lphysiol_full(            & !
                 cpatch%veg_temp(tuco)-t00 & ! Vegetation temperature       [           �C]
               , mixrat*epi                & ! Vapour mixing ratio          [      mol/mol]
               , csite%can_co2(ipa)*1e-6   & ! CO2 mixing ratio             [      mol/mol]
               , parv_o_lai                & ! Absorbed PAR                 [ Ein/m�leaf/s]
               , cpatch%rb(tuco)           & ! Aerodynamic resistance       [          s/m]
               , csite%can_rhos(ipa)       & ! Air density                  [        kg/m�]
               , csite%A_o_max(ipft,ipa)   & ! Max. open photosynth. rate   [�mol/m�leaf/s]
               , csite%A_c_max(ipft,ipa)   & ! Max. closed photosynth. rate [�mol/m�leaf/s]
               , P_op                      & ! Open stomata res. for water  [          s/m]
               , P_cl                      & ! Closed stomata res. for water[          s/m]
               , ci_op                     & ! Open st. internal carbon     [     �mol/mol]
               , ci_cl                     & ! Closed st. internal carbon   [     �mol/mol]
               , ipft                      & ! PFT                          [         ----]
               , csite%can_prss(ipa)       & ! Pressure                     [         N/m�]
               , leaf_resp                 & ! Leaf respiration rate        [�mol/m�leaf/s]
               , green_leaf_factor(ipft)   & ! Fraction of actual green leaves relative to 
                                           ! !      on-allometry value.
               , leaf_aging_factor(ipft)   &
               , csite%old_stoma_data_max(ipft,ipa) &
               , cpatch%llspan(tuco) &
               , cpatch%vm_bar(tuco) &
               , limit_flag )
         end if
      end do
         
   else
      !---- There is no "active" cohort. --------------------------------------------------!
      csite%A_o_max(1:n_pft,ipa) = 0.0
      csite%A_c_max(1:n_pft,ipa) = 0.0
   end if
   !---------------------------------------------------------------------------------------!



   !---------------------------------------------------------------------------------------!
   !    Initialize some variables.                                                         !
   !---------------------------------------------------------------------------------------!
   !----- LAI/rb, summed over all cohorts.  Used in the Euler scheme. ---------------------!
   sum_lai_rbi = 0.0
   !----- Total root biomass (in kgC/m2) and patch sum available water. -------------------!
   pss_available_water = 0.0
   broot_tot           = 0.0
   !----- Initialize variables for transpiration calculation. -----------------------------!
   root_depth_indices(:) = .false.
   !---------------------------------------------------------------------------------------!

   !---------------------------------------------------------------------------------------!
   !    Loop over all cohorts, from tallest to shortest.                                   !
   !---------------------------------------------------------------------------------------!
   cohortloop: do ico = 1,cpatch%ncohorts
         
      !------------------------------------------------------------------------------------!
      !     Only need to worry about photosyn if radiative transfer has been  done for     !
      ! this cohort.                                                                       !
      !------------------------------------------------------------------------------------!
      if (cpatch%solvable(ico)) then

            !----- Alias for PFT ----------------------------------------------------------!
            ipft = cpatch%pft(ico)

            !----- Updating total LAI/RB --------------------------------------------------!
            sum_lai_rbi = sum_lai_rbi + cpatch%lai(ico) / cpatch%rb(ico)

            !------------------------------------------------------------------------------!
            !    Convert specific humidity to mixing ratio.  I am not sure about this one, !
            ! if we should convert here to mixing ratio, or convert everything inside to   !
            ! specific humidity.  Also, scale photosynthetically active radiation per unit !
            ! of leaf.                                                                     !
            !------------------------------------------------------------------------------!
            mixrat     = csite%can_shv(ipa) / (1. - csite%can_shv(ipa))
            parv_o_lai = cpatch%par_v(ico) / cpatch%lai(ico) 

            !----- Calling the photosynthesis for maximum photosynthetic rates. -----------!
            call lphysiol_full(             & !
                 cpatch%veg_temp(ico)-t00   & ! Vegetation temperature      [           �C]
               , mixrat*epi                 & ! Vapour mixing ratio         [      mol/mol]
               , csite%can_co2(ipa)*1e-6    & ! CO2 mixing ratio            [      mol/mol]
               , parv_o_lai                 & ! Absorbed PAR                [ Ein/m�leaf/s]
               , cpatch%rb(ico)             & ! Aerodynamic resistance      [          s/m]
               , csite%can_rhos(ipa)        & ! Air density                 [        kg/m�]
               , cpatch%A_open(ico)         & ! Max. open photos. rate      [�mol/m�leaf/s]
               , cpatch%A_closed(ico)       & ! Max. closed photos. rate    [�mol/m�leaf/s]
               , cpatch%rsw_open(ico)       & ! Open stomata res. for H2O   [          s/m]
               , cpatch%rsw_closed(ico)     & ! Closed stomata res. for H2O [          s/m]
               , cpatch%veg_co2_open(ico)   & ! Open stomata CO2            [     �mol/mol]
               , cpatch%veg_co2_closed(ico) & ! Open stomata CO2            [     �mol/mol]
               , ipft                       & ! PFT                         [         ----]
               , csite%can_prss(ipa)        & ! Pressure                    [         N/m�]
               , leaf_resp                  & ! Leaf respiration rate       [�mol/m�leaf/s]
               , green_leaf_factor(ipft)    & ! Fraction of actual green leaves relative 
                                            ! !      to on-allometry value.
               , leaf_aging_factor(ipft)    & !
               , cpatch%old_stoma_data(ico) & !
               , cpatch%llspan(ico)         & !
               , cpatch%vm_bar(ico)         & ! Type containing the exact stomatal deriv-
                                            ! !     atives and meteorological info
               , limit_flag)                ! ! Which kind of limitation happened?

            !----- Leaf respiration, converting it to [�mol/m�ground/s] -------------------!
            cpatch%leaf_respiration(ico) = leaf_resp * cpatch%lai(ico)
            cpatch%mean_leaf_resp(ico)   = cpatch%mean_leaf_resp(ico)                      &
                                         + cpatch%leaf_respiration(ico)
            cpatch%today_leaf_resp(ico)  = cpatch%today_leaf_resp(ico)                     &
                                         + cpatch%leaf_respiration(ico)

            !----- Demand for water [kg/m2/s].  Psi_open is from last time step. ----------!
            water_demand = cpatch%Psi_open(ico)

            !----- Supply of water. -------------------------------------------------------!
            water_supply = water_conductance(ipft)                                         &
                         * available_liquid_water(cpatch%krdepth(ico)) * wdnsi             &
                         * q(ipft) * cpatch%balive(ico)                                    &
                         / (1.0 + q(ipft) + cpatch%hite(ico) * qsw(ipft) )                 &
                         * cpatch%nplant(ico)

            root_depth_indices(cpatch%krdepth(ico)) = .true.

            broot_loc = q(ipft) * cpatch%balive(ico)                                       &
                      / (1.0 + q(ipft) + cpatch%hite(ico) * qsw(ipft) )                    &
                      * cpatch%nplant(ico)
            broot_tot = broot_tot + broot_loc
            pss_available_water = pss_available_water                                      &
                                + available_liquid_water(cpatch%krdepth(ico)) * broot_loc

            !----- Weighting between open/closed stomata. ---------------------------------!
            cpatch%fsw(ico) = water_supply / max(1.0e-30,water_supply + water_demand)


            !------------------------------------------------------------------------------!
            !      Photorespiration can become important at high temperatures.  If so,     !
            ! close down the stomata.                                                      !
            !------------------------------------------------------------------------------!
            if (cpatch%A_open(ico) < cpatch%A_closed(ico)) then
               cpatch%fs_open(ico) = 0.0
            else
               cpatch%fs_open(ico) = cpatch%fsw(ico) * cpatch%fsn(ico)
            end if

            !----- Net stomatal resistance. -----------------------------------------------!
            cpatch%stomatal_resistance(ico) = 1.0                                          &
                                            / ( cpatch%fs_open(ico)/cpatch%rsw_open(ico)   &
                                              + (1.0 - cpatch%fs_open(ico))                &
                                                / cpatch%rsw_closed(ico) )

            !----- GPP, averaged over frqstate. -------------------------------------------!
            cpatch%gpp(ico)       = cpatch%lai(ico)                                        &
                                  * ( cpatch%fs_open(ico) * cpatch%A_open(ico)             &
                                    + (1.0 - cpatch%fs_open(ico)) * cpatch%A_closed(ico) ) &
                                  + cpatch%leaf_respiration(ico)
            cpatch%mean_gpp(ico)  = cpatch%mean_gpp(ico) + cpatch%gpp(ico)

            !----- GPP, summed over 1 day. [�mol/m�ground] --------------------------------!
            cpatch%today_gpp(ico) = cpatch%today_gpp(ico) + cpatch%gpp(ico)

            !----- Potential GPP if no N limitation. [�mol/m�ground] ----------------------!
            cpatch%today_gpp_pot(ico) = cpatch%today_gpp_pot(ico)                          &
                                      + cpatch%lai(ico)                                    &
                                      * ( cpatch%fsw(ico) * cpatch%A_open(ico)             &
                                        + (1.0 - cpatch%fsw(ico)) * cpatch%A_closed(ico))  &
                                      + cpatch%leaf_respiration(ico)

            !----- Maximum GPP if at the top of the canopy [�mol/m�ground] ----------------!
            cpatch%today_gpp_max(ico) = cpatch%today_gpp_max(ico)                          &
                                      + cpatch%lai(ico)                                    &
                                      * ( cpatch%fs_open(ico) * csite%A_o_max(ipft,ipa)    &
                                        + (1.0 - cpatch%fs_open(ico))                      &
                                          * csite%A_c_max(ipft,ipa))                       &
                                      + cpatch%leaf_respiration(ico)

      else
         !----- If the cohort wasn't solved, we must assign some zeroes. ------------------!
         cpatch%A_open(ico)              = 0.0
         cpatch%A_closed(ico)            = 0.0
         cpatch%Psi_open(ico)            = 0.0
         cpatch%Psi_closed(ico)          = 0.0
         cpatch%rsw_open(ico)            = 0.0
         cpatch%rsw_closed(ico)          = 0.0
         cpatch%rb(ico)                  = 0.0
         cpatch%stomatal_resistance(ico) = 0.0
         cpatch%gpp(ico)                 = 0.0
         cpatch%leaf_respiration(ico)    = 0.0
         limit_flag                      = 0
      end if
      
      !------------------------------------------------------------------------------------!
      !    Not really a part of the photosynthesis scheme, but this will do it.  We must   !
      ! integrate the "mean" of the remaining respiration terms, except for the root one.  !
      ! This is done regardless on whether the cohort is doing photosynthesis.  Also, we   !
      ! convert units so all fast respiration terms are in [�mol/m�ground/s].              !
      !------------------------------------------------------------------------------------!
      cpatch%mean_growth_resp (ico) = cpatch%mean_growth_resp (ico)                        &
                                    + cpatch%growth_respiration (ico) * kgCday_2_umols     &
                                    * cpatch%nplant(ico)
      cpatch%mean_storage_resp(ico) = cpatch%mean_storage_resp(ico)                        &
                                    + cpatch%storage_respiration(ico) * kgCday_2_umols     &
                                    * cpatch%nplant(ico)
      cpatch%mean_vleaf_resp  (ico) = cpatch%mean_vleaf_resp  (ico)                        &
                                    + cpatch%vleaf_respiration  (ico) * kgCday_2_umols     &
                                    * cpatch%nplant(ico)                                    
      !------------------------------------------------------------------------------------!

      if (print_photo_debug) then
         call print_photo_details(cmet,csite,ipa,ico,limit_flag)
      end if
   end do cohortloop

   !---------------------------------------------------------------------------------------!
   !     Add the contribution of this time step to the average available water.            !
   !---------------------------------------------------------------------------------------!
   if (broot_tot > 1.e-20) then
      csite%avg_available_water(ipa) = csite%avg_available_water(ipa)                      &
                                     + pss_available_water / broot_tot
   !else
   !  Add nothing, the contribution of this time is zero since no cohort can transpire... 
   end if

   !---------------------------------------------------------------------------------------!
   !     For plants of a given rooting depth, determine soil level from which transpired   !
   ! water is to be extracted.                                                             !
   !---------------------------------------------------------------------------------------!
   ed_ktrans(:) = 0
   do k1 = lsl, mzg
      !---- Assign a very large negative, so it will update it at least once. -------------!
      swp = -huge(1.)
      if (root_depth_indices(k1)) then
         do k2 = k1, mzg
            nsoil = csite%ntext_soil(k2,ipa)
            !------------------------------------------------------------------------------!
            !      Find slpotv using the available liquid water, since ice is unavailable  !
            ! for transpiration.                                                           !
            !------------------------------------------------------------------------------!
            slpotv = soil(nsoil)%slpots * csite%soil_fracliq(k2,ipa)                       &
                   * (soil(nsoil)%slmsts / csite%soil_water(k2,ipa)) ** soil(nsoil)%slbs

            !------------------------------------------------------------------------------!
            !      Find layer in root zone with highest slpotv AND soil_water above        !
            ! minimum soilwp.  Set ktrans to this layer.                                   !
            !------------------------------------------------------------------------------!
            if (slpotv > swp .and. csite%soil_water(k2,ipa) > soil(nsoil)%soilwp) then
               swp = slpotv
               ed_ktrans(k1) = k2
            end if
         end do
      end if
   end do

   return
end subroutine canopy_photosynthesis
!==========================================================================================!
!==========================================================================================!






!==========================================================================================!
!==========================================================================================!
!     This sub-routine prints some extra information on the photosynthesis driver in a     !
! convenient ascii file for debugging purposes.                                            !
!------------------------------------------------------------------------------------------!
subroutine print_photo_details(cmet,csite,ipa,ico,limit_flag)
   use ed_max_dims    , only : str_len        ! ! intent(in)
   use ed_state_vars  , only : sitetype       & ! structure
                             , patchtype      ! ! structure
   use met_driver_coms, only : met_driv_state ! ! structure
   use physiology_coms, only : photo_prefix   ! ! intent(in)
   use ed_misc_coms   , only : current_time   ! ! intent(in)
   implicit none
   !----- Arguments. ----------------------------------------------------------------------!
   type(sitetype)            , target      :: csite           ! Current site
   type(met_driv_state)      , target      :: cmet            ! Current met. conditions.
   integer                   , intent(in)  :: ipa             ! Current patch number
   integer                   , intent(in)  :: ico             ! Current cohort number
   integer                   , intent(in)  :: limit_flag      ! Limitation flag
   !----- Local variables. ----------------------------------------------------------------!
   type(patchtype)           , pointer     :: cpatch          ! Current site
   character(len=str_len)                  :: photo_fout      ! File with the cohort info
   integer                                 :: ipft
   integer                                 :: jco
   logical                                 :: isthere
   real                                    :: leaf_resp
   real                                    :: stom_resist
   real                                    :: parv
   real                                    :: parv_o_lai
   !----- Local constants. ----------------------------------------------------------------!
   character(len=10), parameter :: hfmt='(42(a,1x))'
   character(len=48), parameter :: bfmt='(3(i13,1x),1(es13.6,1x),2(i13,1x),36(es13.6,1x))'
   !----- Locally saved variables. --------------------------------------------------------!
   logical                   , save        :: first_time=.true.
   !---------------------------------------------------------------------------------------!


   !----- Make some aliases. --------------------------------------------------------------!
   cpatch      => csite%patch(ipa)
   ipft        =  cpatch%pft(ico)
   leaf_resp   =  cpatch%leaf_respiration(ico)
   stom_resist =  cpatch%stomatal_resistance(ico)
   !---------------------------------------------------------------------------------------!

   if (cpatch%solvable(ico)) then
      parv       = 1.0e6 * cpatch%par_v(ico)
      parv_o_lai = 1.0e6 * cpatch%par_v(ico) / cpatch%lai(ico) 
   else
      parv_o_lai = 0.0
   end if

   !---------------------------------------------------------------------------------------!
   !     First time here.  Delete all files.                                               !
   !---------------------------------------------------------------------------------------!
   if (first_time) then
      do jco = 1, cpatch%ncohorts
         write (photo_fout,fmt='(a,i4.4,a)') trim(photo_prefix),jco,'.txt'
         inquire(file=trim(photo_fout),exist=isthere)
         if (isthere) then
            !---- Open the file to delete when closing. -----------------------------------!
            open (unit=57,file=trim(photo_fout),status='old',action='write')
            close(unit=57,status='delete')
         end if
      end do
      first_time = .false.
   end if
   !---------------------------------------------------------------------------------------!




   !----- Create the file name. -----------------------------------------------------------!
   write (photo_fout,fmt='(a,i4.4,a)') trim(photo_prefix),ico,'.txt'
   !---------------------------------------------------------------------------------------!



   !---------------------------------------------------------------------------------------!
   !    Check whether the file exists or not.  In case it doesn't, create it and add the   !
   ! header.                                                                               !
   !---------------------------------------------------------------------------------------!
   inquire(file=trim(photo_fout),exist=isthere)
   if (.not. isthere) then
      open  (unit=57,file=trim(photo_fout),status='replace',action='write')
      write (unit=57,fmt=hfmt)   '         YEAR', '        MONTH', '          DAY'         &
                               , '         TIME', '          PFT', '   LIMIT_FLAG'         &
                               , '       HEIGHT', '       NPLANT', '        BLEAF'         &
                               , '          LAI', '      HCAPVEG', '    VEG_WATER'         &
                               , '     VEG_TEMP', '     CAN_TEMP', '     ATM_TEMP'         &
                               , '  GROUND_TEMP', '      CAN_SHV', '      ATM_SHV'         &
                               , '   GROUND_SHV', '     ATM_PRSS', '     CAN_PRSS'         &
                               , '         PCPG', '     CAN_RHOS', '      ATM_CO2'         &
                               , '      CAN_CO2', ' VEG_CO2_OPEN', ' VEG_CO2_CLOS'         &
                               , '         PARV', '   PARV_O_LAI', '          GPP'         &
                               , '    LEAF_RESP', '           RB', '  STOM_RESIST'         &
                               , '       A_OPEN', '       A_CLOS', '     RSW_OPEN'         &
                               , '     RSW_CLOS', '     PSI_OPEN', '     PSI_CLOS'         &
                               , '          FSW', '          FSN', '      FS_OPEN'
                               
                               
      close (unit=57,status='keep')
   end if
   !---------------------------------------------------------------------------------------!



   !---------------------------------------------------------------------------------------!
   !     Re-open the file at the last line, and include the current status.                !
   !---------------------------------------------------------------------------------------!
   open (unit=57,file=trim(photo_fout),status='old',action='write',position='append')
   write(unit=57,fmt=bfmt)                                                                 &
        current_time%year         , current_time%month        , current_time%date          &
      , current_time%time         , cpatch%pft(ico)           , limit_flag                 &
      , cpatch%hite(ico)          , cpatch%nplant(ico)        , cpatch%bleaf(ico)          &
      , cpatch%lai(ico)           , cpatch%hcapveg(ico)       , cpatch%veg_water(ico)      &
      , cpatch%veg_temp(ico)      , csite%can_temp(ipa)       , cmet%atm_tmp               &
      , csite%ground_temp(ipa)    , csite%can_shv(ipa)        , cmet%atm_shv               &
      , csite%ground_shv(ipa)     , cmet%prss                 , csite%can_prss(ipa)        &
      , cmet%pcpg                 , csite%can_rhos(ipa)       , cmet%atm_co2               &
      , csite%can_co2(ipa)        , cpatch%veg_co2_open(ico)  , cpatch%veg_co2_closed(ico) &
      , parv                      , parv_o_lai                , cpatch%gpp(ico)            &
      , leaf_resp                 , cpatch%rb(ico)            , stom_resist                &
      , cpatch%A_open(ico)        , cpatch%A_closed(ico)      , cpatch%rsw_open(ico)       &
      , cpatch%rsw_closed(ico)    , cpatch%Psi_open(ico)      , cpatch%Psi_closed(ico)     &
      , cpatch%fsw(ico)           , cpatch%fsn(ico)           , cpatch%fs_open(ico)
      
      
                   
   close(unit=57,status='keep')
   !---------------------------------------------------------------------------------------!

   return
end subroutine print_photo_details
!==========================================================================================!
!==========================================================================================!
