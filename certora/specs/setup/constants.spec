// Shared numeric constants for standalone pure-math targets (PriceLib, Ratifier).

definition WAD() returns mathint = 10^18;             // 1e18
definition MAX_FEE_RATE() returns mathint = 5 * 10^17; // 0.5e18
definition MAX_FEE_RATE_FIXED_TO_VARIABLE() returns mathint = 0; // fees disabled on fixed-to-variable exits (Midnight->Blue, Midnight->Vault)
definition MAX_TICK() returns mathint = 6744;          // tickToPrice domain upper bound (TickLib.MAX_TICK)
