# A "zap" to deposit/withdraw Curve contract without too many transactions
from vyper.interfaces import ERC20
import cERC20 as cERC20


# Tether transfer-only ABI
contract USDT:
    def transfer(_to: address, _value: uint256): modifying
    def transferFrom(_from: address, _to: address, _value: uint256): modifying


contract Curve:
    def add_liquidity(amounts: uint256[N_COINS], min_mint_amount: uint256): modifying
    def remove_liquidity(_amount: uint256, min_amounts: uint256[N_COINS]): modifying
    def remove_liquidity_imbalance(amounts: uint256[N_COINS], max_burn_amount: uint256): modifying
    def balances(i: int128) -> uint256: constant
    def A() -> uint256: constant
    def fee() -> uint256: constant


N_COINS: constant(int128) = ___N_COINS___
TETHERED: constant(bool[N_COINS]) = ___TETHERED___
USE_LENDING: constant(bool[N_COINS]) = ___USE_LENDING___
ZERO256: constant(uint256) = 0  # This hack is really bad XXX
ZEROS: constant(uint256[N_COINS]) = ___N_ZEROS___  # <- change
LENDING_PRECISION: constant(uint256) = 10 ** 18
PRECISION: constant(uint256) = 10 ** 18
PRECISION_MUL: constant(uint256[N_COINS]) = ___PRECISION_MUL___
FEE_DENOMINATOR: constant(uint256) = 10 ** 10
FEE_IMPRECISION: constant(uint256) = 10 ** 6  # 0.01%

coins: public(address[N_COINS])
underlying_coins: public(address[N_COINS])
curve: public(address)
token: public(address)


@public
def __init__(_coins: address[N_COINS], _underlying_coins: address[N_COINS],
             _curve: address, _token: address):
    self.coins = _coins
    self.underlying_coins = _underlying_coins
    self.curve = _curve
    self.token = _token


@public
@nonreentrant('lock')
def add_liquidity(uamounts: uint256[N_COINS], min_mint_amount: uint256):
    use_lending: bool[N_COINS] = USE_LENDING
    tethered: bool[N_COINS] = TETHERED
    amounts: uint256[N_COINS] = ZEROS

    for i in range(N_COINS):
        uamount: uint256 = uamounts[i]

        # Transfer the underlying coin from owner
        if tethered[i]:
            USDT(self.underlying_coins[i]).transferFrom(
                msg.sender, self, uamount)
        else:
            assert_modifiable(ERC20(self.underlying_coins[i])\
                .transferFrom(msg.sender, self, uamount))

        # Mint if needed
        if use_lending[i]:
            ERC20(self.underlying_coins[i]).approve(self.coins[i], uamount)
            ok: uint256 = cERC20(self.coins[i]).mint(uamount)
            if ok > 0:
                raise "Could not mint coin"
            amounts[i] = cERC20(self.coins[i]).balanceOf(self)
            ERC20(self.coins[i]).approve(self.curve, amounts[i])
        else:
            amounts[i] = uamount
            ERC20(self.underlying_coins[i]).approve(self.curve, uamount)

    Curve(self.curve).add_liquidity(amounts, min_mint_amount)

    tokens: uint256 = ERC20(self.token).balanceOf(self)
    assert_modifiable(ERC20(self.token).transfer(msg.sender, tokens))


@private
def _send_all(_addr: address, min_uamounts: uint256[N_COINS]):
    use_lending: bool[N_COINS] = USE_LENDING
    tethered: bool[N_COINS] = TETHERED

    for i in range(N_COINS):
        if use_lending[i]:
            _coin: address = self.coins[i]
            ok: uint256 = cERC20(_coin).redeem(cERC20(_coin).balanceOf(self))
            if ok > 0:
                raise "Could not redeem coin"

        _ucoin: address = self.underlying_coins[i]
        _uamount: uint256 = ERC20(_ucoin).balanceOf(self)
        assert _uamount >= min_uamounts[i], "Not enough coins withdrawn"

        if tethered[i]:
            USDT(_ucoin).transfer(_addr, _uamount)
        else:
            assert_modifiable(ERC20(_ucoin).transfer(_addr, _uamount))


@public
@nonreentrant('lock')
def remove_liquidity(_amount: uint256, min_uamounts: uint256[N_COINS]):
    zeros: uint256[N_COINS] = ZEROS

    assert_modifiable(ERC20(self.token).transferFrom(msg.sender, self, _amount))
    Curve(self.curve).remove_liquidity(_amount, zeros)

    self._send_all(msg.sender, min_uamounts)


@public
@nonreentrant('lock')
def remove_liquidity_imbalance(uamounts: uint256[N_COINS], max_burn_amount: uint256):
    """
    Get max_burn_amount in, remove requested liquidity and transfer back what is left
    """
    use_lending: bool[N_COINS] = USE_LENDING
    tethered: bool[N_COINS] = TETHERED
    _token: address = self.token

    amounts: uint256[N_COINS] = uamounts
    for i in range(N_COINS):
        if use_lending[i]:
            rate: uint256 = cERC20(self.coins[i]).exchangeRateCurrent()
            amounts[i] = amounts[i] * rate / LENDING_PRECISION
        # if not use_lending - all good already

    # Transfrer max tokens in
    _tokens: uint256 = ERC20(_token).balanceOf(msg.sender)
    if _tokens > max_burn_amount:
        _tokens = max_burn_amount
    assert_modifiable(ERC20(_token).transferFrom(msg.sender, self, _tokens))

    Curve(self.curve).remove_liquidity_imbalance(amounts, max_burn_amount)

    # Transfer unused tokens back
    _tokens = ERC20(_token).balanceOf(self)
    assert_modifiable(ERC20(_token).transfer(msg.sender, _tokens))

    # Unwrap and transfer all the coins we've got
    self._send_all(msg.sender, ZEROS)


@private
@constant
def _xp_mem(rates: uint256[N_COINS], _balances: uint256[N_COINS]) -> uint256[N_COINS]:
    result: uint256[N_COINS] = rates
    for i in range(N_COINS):
        result[i] = result[i] * _balances[i] / PRECISION
    return result


@private
@constant
def get_D(A: uint256, xp: uint256[N_COINS]) -> uint256:
    S: uint256 = 0
    for _x in xp:
        S += _x
    if S == 0:
        return 0

    Dprev: uint256 = 0
    D: uint256 = S
    Ann: uint256 = A * N_COINS
    for _i in range(255):
        D_P: uint256 = D
        for _x in xp:
            D_P = D_P * D / (_x * N_COINS + 1)  # +1 is to prevent /0
        Dprev = D
        D = (Ann * S + D_P * N_COINS) * D / ((Ann - 1) * D + (N_COINS + 1) * D_P)
        # Equality with the precision of 1
        if D > Dprev:
            if D - Dprev <= 1:
                break
        else:
            if Dprev - D <= 1:
                break
    return D


@private
@constant
def get_y(A: uint256, i: int128, _xp: uint256[N_COINS], D: uint256) -> uint256:
    """
    Calculate x[i] if one reduces D from being calculated for _xp to D

    Done by solving quadratic equation iteratively.
    x_1**2 + x1 * (sum' - (A*n**n - 1) * D / (A * n**n)) = D ** (n + 1) / (n ** (2 * n) * prod' * A)
    x_1**2 + b*x_1 = c

    x_1 = (x_1**2 + c) / (2*x_1 + b)
    """
    # x in the input is converted to the same price/precision

    assert (i >= 0) and (i < N_COINS)

    c: uint256 = D
    S_: uint256 = 0
    Ann: uint256 = A * N_COINS

    _x: uint256 = 0
    for _i in range(N_COINS):
        if _i != i:
            _x = _xp[_i]
        else:
            continue
        S_ += _x
        c = c * D / (_x * N_COINS)
    c = c * D / (Ann * N_COINS)
    b: uint256 = S_ + D / Ann
    y_prev: uint256 = 0
    y: uint256 = D
    for _i in range(255):
        y_prev = y
        y = (y*y + c) / (2 * y + b - D)
        # Equality with the precision of 1
        if y > y_prev:
            if y - y_prev <= 1:
                break
        else:
            if y_prev - y <= 1:
                break
    return y


@public
@nonreentrant('lock')
def remove_liquidity_one_coin(_token_amount: uint256, i: int128, min_uamount: uint256):
    """
    Remove _amount of liquidity all in a form of coin i
    """
    # First, need to calculate
    # * Get current D
    # * Solve Eqn against y_i for D - _token_amount
    use_lending: bool[N_COINS] = USE_LENDING
    tethered: bool[N_COINS] = TETHERED
    rates: uint256[N_COINS] = ZEROS
    crv: address = self.curve
    A: uint256 = Curve(crv).A()
    fee: uint256 = Curve(crv).fee()* N_COINS / (2 * (N_COINS - 1))

    xp: uint256[N_COINS] = PRECISION_MUL
    S: uint256 = 0
    for j in range(N_COINS):
        xp[j] *= Curve(crv).balances(j)
        if use_lending[j]:
            rate: uint256 = cERC20(self.coins[j]).exchangeRateCurrent()
            xp[j] = xp[j] * rate / LENDING_PRECISION
            rates[j] = rate
        else:
            rates[j] = LENDING_PRECISION
        S += xp[j]
        # if not use_lending - all good already
    fee -= fee * xp[i] / S  # Not the case if too much off the peg
    fee += fee * FEE_IMPRECISION / FEE_DENOMINATOR  # Overcharge to account for imprecision

    D0: uint256 = self.get_D(A, xp)
    D1: uint256 = D0 - _token_amount
    y: uint256 = self.get_y(A, i, xp, D1)
    for j in range(N_COINS):
        # Symmetric withdrawal
        xp[j] = xp[j] * D1 / D0
