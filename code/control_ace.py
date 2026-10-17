# admv1018_control.py

import clr
import sys
import time
import argparse

ACE_CLIENT_PATH = r"C:\Program Files (x86)\Analog Devices\ACE\Client"

CONTEXT_PATH = r"\System\Subsystem_1\ADMV1018-049394 RevA\ADMV1018"
NAV_PATH = "Root::System.Subsystem_1.ADMV1018-049394 RevA.ADMV1018"

REG_TX_DSA_CTRL  = 0x020A
REG_TX_DSA_RANGE = 0x020C
REG_RX_DSA_CTRL  = 0x0106

TX_DSA_RANGE_VALUE = 0xAC


def connect_ace():
    sys.path.append(ACE_CLIENT_PATH)
    clr.AddReference("AnalogDevices.Csa.Remoting.Clients")

    import AnalogDevices.Csa.Remoting.Clients as adrc

    client_manager = adrc.ClientManager.Create()
    client = client_manager.CreateRequestClient("localhost:2357")

    client.set_ContextPath(CONTEXT_PATH)
    client.NavigateToPath(NAV_PATH)

    return client


def check_attenuation(value):
    if value < 0 or value > 15:
        raise ValueError("Attenuation must be between 0 and 15.")


def set_tx_attenuator_1(client, atten):
    """
    TX attenuator 1: LSB nibble of TX_DSA_CTRL.
    atten = 0 to 15
    """
    check_attenuation(atten)

    current = client.ReadRegister(REG_TX_DSA_CTRL)
    # Convertimos a enteros por si vienen como texto desde la consola o desde el ACE
    current_int = int(current, 16) if isinstance(current, str) and 'x' in str(current).lower() else int(current)
    atten_int = int(atten)

    new_value = (current_int & 0xF0) | (atten_int & 0x0F)

    client.WriteRegister(REG_TX_DSA_RANGE, TX_DSA_RANGE_VALUE)
    time.sleep(0.05)

    client.WriteRegister(REG_TX_DSA_CTRL, new_value)
    time.sleep(0.05)

    return new_value


def set_tx_attenuator_2(client, atten):
    """
    TX attenuator 2: MSB nibble of TX_DSA_CTRL.
    atten = 0 to 15
    """
    check_attenuation(atten)

    current = client.ReadRegister(REG_TX_DSA_CTRL)
    # Convertimos a enteros por si vienen como texto desde la consola o desde el ACE
    current_int = int(current, 16) if isinstance(current, str) and 'x' in str(current).lower() else int(current)
    atten_int = int(atten)

    new_value = ((atten_int & 0x0F) << 4) | (current_int & 0x0F)

    client.WriteRegister(REG_TX_DSA_RANGE, TX_DSA_RANGE_VALUE)
    time.sleep(0.05)

    client.WriteRegister(REG_TX_DSA_CTRL, new_value)
    time.sleep(0.05)

    return new_value


def set_tx_both_attenuators(client, atten1, atten2):
    """
    TX attenuator 1: LSB
    TX attenuator 2: MSB
    """
    check_attenuation(atten1)
    check_attenuation(atten2)

    new_value = ((atten2 & 0x0F) << 4) | (atten1 & 0x0F)

    client.WriteRegister(REG_TX_DSA_RANGE, TX_DSA_RANGE_VALUE)
    time.sleep(0.05)

    client.WriteRegister(REG_TX_DSA_CTRL, new_value)
    time.sleep(0.05)

    return new_value


def set_rx_attenuator(client, atten):
    """
    RX attenuator:
    MSB fixed at 0x1.
    LSB controls attenuation from 0 to 15.

    Example:
    atten = 14 -> 0x1E
    """
    check_attenuation(atten)

    new_value = 0x10 | (atten & 0x0F)

    client.WriteRegister(REG_RX_DSA_CTRL, new_value)
    time.sleep(0.05)

    return new_value


def main():
    parser = argparse.ArgumentParser(description="ADMV1018 DSA control from MATLAB/Python.")

    parser.add_argument(
        "--target",
        required=True,
        choices=["tx1", "tx2", "txboth", "rx"],
        help="Attenuator target: tx1, tx2, txboth, or rx."
    )

    parser.add_argument(
        "--atten",
        type=int,
        help="Attenuation value from 0 to 15."
    )

    parser.add_argument(
        "--atten1",
        type=int,
        help="TX attenuator 1 value from 0 to 15."
    )

    parser.add_argument(
        "--atten2",
        type=int,
        help="TX attenuator 2 value from 0 to 15."
    )

    args = parser.parse_args()

    client = connect_ace()

    if args.target == "tx1":
        if args.atten is None:
            raise ValueError("Use --atten for tx1.")
        value = set_tx_attenuator_1(client, args.atten)

    elif args.target == "tx2":
        if args.atten is None:
            raise ValueError("Use --atten for tx2.")
        value = set_tx_attenuator_2(client, args.atten)

    elif args.target == "txboth":
        if args.atten1 is None or args.atten2 is None:
            raise ValueError("Use --atten1 and --atten2 for txboth.")
        value = set_tx_both_attenuators(client, args.atten1, args.atten2)

    elif args.target == "rx":
        if args.atten is None:
            raise ValueError("Use --atten for rx.")
        value = set_rx_attenuator(client, args.atten)

    print(f"OK: {args.target} set. Register value = 0x{value:02X}")


if __name__ == "__main__":
    main()