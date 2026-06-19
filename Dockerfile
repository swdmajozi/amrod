FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Copy project files
COPY ["src/Api/Api.csproj", "src/Api/"]
COPY ["src/Data/Data.csproj", "src/Data/"]
COPY ["src/Domain/Domain.csproj", "src/Domain/"]

# Restore packages
RUN dotnet restore "src/Api/Api.csproj"

# Copy source code
COPY . .

# Build
RUN dotnet build "src/Api/Api.csproj" -c Release -o /app/build

# Publish
FROM build AS publish
RUN dotnet publish "src/Api/Api.csproj" -c Release -o /app/publish /p:UseAppHost=false

# Runtime image
FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=publish /app/publish .

EXPOSE 80 443
ENTRYPOINT ["dotnet", "Api.dll"]
