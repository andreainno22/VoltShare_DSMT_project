package it.unipi.dsmt.voltshare.service;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * The price of a session. Pure arithmetic, no database, no cluster — and the part of billing
 * most likely to be quietly wrong, since a rounding mistake produces a plausible number.
 */
class BillingServiceTest {

    private static final int TARIFF = 45;      // cents per kWh, station 1 in the seed
    private static final int OVERSTAY = 50;    // cents per minute, the default

    @Test
    void energyOnly() {
        // 10 kWh at 45 c/kWh = 450 cents
        assertEquals(450, BillingService.cost(10.0, TARIFF, 0, OVERSTAY));
    }

    @Test
    void freeSessionCostsNothing() {
        assertEquals(0, BillingService.cost(0.0, TARIFF, 0, OVERSTAY));
    }

    @Test
    void binaryFloatingPointDoesNotLeakIntoTheTotal() {
        // 41.2 * 45 is 1854.0000000000002 as a double: rounding that with a cast to int
        // would still give 1854 here, but the same trick on a value landing just under an
        // integer silently loses a cent. BigDecimal is what keeps this exact.
        assertEquals(1854, BillingService.cost(41.2, TARIFF, 0, OVERSTAY));
        assertEquals(3, BillingService.cost(0.07, 45, 0, OVERSTAY));   // 3.15 → 3
    }

    @Test
    void halfACentRoundsUp() {
        // 0.1 kWh at 45 c/kWh = 4.5 cents. HALF_UP, so the customer pays 5.
        assertEquals(5, BillingService.cost(0.1, TARIFF, 0, OVERSTAY));
    }

    @Test
    void overstayIsChargedByStartedMinute() {
        // One second past the grace period already costs a full minute: rounding down
        // would make the first minute free, which is the opposite of a deterrent.
        assertEquals(OVERSTAY, BillingService.cost(0.0, TARIFF, 1, OVERSTAY));
        assertEquals(OVERSTAY, BillingService.cost(0.0, TARIFF, 60, OVERSTAY));
        assertEquals(2 * OVERSTAY, BillingService.cost(0.0, TARIFF, 61, OVERSTAY));
        assertEquals(3 * OVERSTAY, BillingService.cost(0.0, TARIFF, 180, OVERSTAY));
    }

    @Test
    void graceIsNotSubtractedTwice() {
        // The station writes overstay_seconds with the five-minute grace already removed.
        // If the back office subtracted it again, this would come out at zero.
        int oneMinutePastGrace = 60;
        assertEquals(OVERSTAY, BillingService.cost(0.0, TARIFF, oneMinutePastGrace, OVERSTAY));
    }

    @Test
    void energyAndOverstayAddUp() {
        // 20 kWh at 45 c = 900, plus 4 minutes of overstay at 50 c = 200
        assertEquals(1100, BillingService.cost(20.0, TARIFF, 4 * 60, OVERSTAY));
    }

    @Test
    void aFreeStationStillChargesForOverstay() {
        // tariff 0 is a legitimate configuration (a promotional site); the connector is
        // still a scarce resource, so occupying it is not free.
        assertEquals(OVERSTAY, BillingService.cost(30.0, 0, 30, OVERSTAY));
    }

    /**
     * The overstay rate is per station, like the energy tariff — it is a column of
     * {@code stations}, not a deployment-wide setting. The first version of the sweep read it
     * from an environment variable instead, so the same formula mixed a per-station price with
     * a global one and the column existed unread. Nothing failed, because both were 50.
     *
     * <p>This is the test that would have caught it, and the reason it is written with two
     * different rates: a regression here is invisible to any test that uses only one.
     */
    @Test
    void overstayIsPricedByTheStationsOwnRate() {
        int pisa = 50;
        int livorno = 80;
        int fiveMinutes = 5 * 60;

        assertEquals(250, BillingService.cost(0.0, TARIFF, fiveMinutes, pisa));
        assertEquals(400, BillingService.cost(0.0, TARIFF, fiveMinutes, livorno));
    }

    @Test
    void negativeInputIsRejectedRatherThanPriced() {
        // A malformed row must not silently produce a credit.
        assertThrows(IllegalArgumentException.class,
                () -> BillingService.cost(-1.0, TARIFF, 0, OVERSTAY));
        assertThrows(IllegalArgumentException.class,
                () -> BillingService.cost(1.0, TARIFF, -1, OVERSTAY));
    }
}
