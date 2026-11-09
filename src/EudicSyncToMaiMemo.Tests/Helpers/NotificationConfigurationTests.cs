using EudicSyncToMaiMemo.Models.Configuration;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace EudicSyncToMaiMemo.Tests.Helpers;

public class NotificationConfigurationTests
{
    [Fact]
    public void EmptyNotificationFlagCannotBindToBoolean()
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(
            new Dictionary<string, string?> { ["Notification:Enabled"] = "" }).Build();

        Assert.Throws<InvalidOperationException>(() =>
            configuration.GetSection("Notification").Get<NotificationOptions>());
    }

    [Theory]
    [InlineData("false", false)]
    [InlineData("true", true)]
    public void ExplicitNotificationFlagBindsWithoutCredentials(string value, bool expected)
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(
            new Dictionary<string, string?> { ["Notification:Enabled"] = value }).Build();

        Assert.Equal(expected, configuration.GetSection("Notification").Get<NotificationOptions>()!.Enabled);
    }
}
